// SpotiglassEQDriver/EQRouter.cpp
//
// Routes EQ-processed audio from inside the AudioServerPlugIn's DoIOOperation
// to a real hardware output device. Without this forwarder, audio written to
// the Spotiglass EQ virtual device would have nowhere to go and the user
// would hear silence after switching default output to "Spotiglass EQ".
//
// The plugin opens a public-client AudioDeviceIOProc on the target device
// (read from a one-shot file written by the Swift host: see
// EqualizerHALPluginController). Processed frames are pushed via a
// single-producer/single-consumer ring buffer; the target device's IOProc
// drains the ring on its own IO thread and emits the samples on the real
// hardware's stream.
//
// **Output-scope only.** The router NEVER opens an input IOProc, NEVER reads
// from any input stream, and NEVER touches the microphone. Audio Recording
// permission is unreachable from this code path by construction; see the
// `scripts/eq-mic-permission-audit.sh` allowlist which whitelists this file
// and grep-asserts for the absence of banned APIs.

#include "EQRouter.h"

#include <CoreAudio/AudioHardware.h>
#include <CoreFoundation/CoreFoundation.h>

#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <new>
#include <sched.h>
#include <unistd.h>

// Diagnostic log path used during bring-up. Writes from inside coreaudiod
// otherwise vanish into the audio-driver subsystem; a flat file is the
// simplest way to confirm StartIO ran, what target UID was read, and whether
// AudioDeviceCreateIOProcID + AudioDeviceStart returned noErr. Compiled to
// a no-op unless SPOTIGLASS_EQ_DEBUG is defined at build time.
static void EQR_log(const char* fmt, ...) {
#if defined(SPOTIGLASS_EQ_DEBUG)
    FILE* f = fopen("/tmp/com.isaaclins.spotiglass.eq.router.log", "a");
    if (!f) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
#else
    (void)fmt;
#endif
}

namespace {

constexpr const char* kRouterStatusPath = "/tmp/com.isaaclins.spotiglass.eq.router.status";
std::atomic<unsigned long long> gStatusSerial{0};

void WriteRouterStatus(const char* state, const char* target_uid, int reason_code) {
    if (!state || !target_uid || target_uid[0] == '\0') return;

    const unsigned long long serial =
        gStatusSerial.fetch_add(1, std::memory_order_relaxed);
    char temporary_path[256] = {0};
    std::snprintf(
        temporary_path,
        sizeof(temporary_path),
        "%s.tmp.%d.%llu",
        kRouterStatusPath,
        static_cast<int>(getpid()),
        serial
    );
    FILE* f = fopen(temporary_path, "w");
    if (!f) return;
    if (strcmp(state, "ready") == 0) {
        fprintf(f, "ready\n%s\n", target_uid);
    } else {
        fprintf(f, "failed\n%s\n%d\n", target_uid, reason_code);
    }
    fclose(f);
    if (rename(temporary_path, kRouterStatusPath) != 0) {
        unlink(temporary_path);
    }
}

// 32 KiB of stereo float32 frames = 4096 frames = ~85 ms at 48 kHz. Large
// enough to absorb a few IO cycles of skew between the EQ device and the
// target device, but small enough that audio falls behind clearly if the
// pipeline stalls (rather than masking a stuck producer).
constexpr size_t kRingFrames = 4096;
constexpr size_t kChannels = 2;

struct Ring {
    float buffer[kRingFrames * kChannels];
    std::atomic<size_t> read_pos{0};
    std::atomic<size_t> write_pos{0};
};

AudioObjectID FindDeviceByUID(const char* uid) {
    if (!uid) return kAudioObjectUnknown;
    CFStringRef cfUID = CFStringCreateWithCString(
        kCFAllocatorDefault, uid, kCFStringEncodingUTF8
    );
    if (!cfUID) return kAudioObjectUnknown;

    AudioValueTranslation trans = {};
    AudioObjectID deviceID = kAudioObjectUnknown;
    trans.mInputData = const_cast<void*>(static_cast<const void*>(&cfUID));
    trans.mInputDataSize = sizeof(cfUID);
    trans.mOutputData = &deviceID;
    trans.mOutputDataSize = sizeof(deviceID);

    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDeviceForUID,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = sizeof(trans);
    OSStatus status = AudioObjectGetPropertyData(
        kAudioObjectSystemObject, &addr, 0, nullptr, &size, &trans
    );
    CFRelease(cfUID);
    return (status == noErr) ? deviceID : kAudioObjectUnknown;
}

bool SupportsFloat32StereoOutput(AudioObjectID device) {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyStreamFormat,
        kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };
    AudioStreamBasicDescription format = {};
    UInt32 size = sizeof(format);
    const OSStatus status = AudioObjectGetPropertyData(
        device, &address, 0, nullptr, &size, &format
    );
    if (status != noErr || size != sizeof(format)) return false;
    if (format.mFormatID != kAudioFormatLinearPCM ||
        (format.mFormatFlags & kAudioFormatFlagIsFloat) == 0 ||
        (format.mFormatFlags & kAudioFormatFlagIsPacked) == 0 ||
        format.mBitsPerChannel != 32 || format.mChannelsPerFrame != kChannels) {
        return false;
    }
    const bool non_interleaved =
        (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    const UInt32 bytes_per_frame = non_interleaved
        ? sizeof(Float32)
        : sizeof(Float32) * kChannels;
    return format.mBytesPerFrame == bytes_per_frame &&
        format.mBytesPerPacket == bytes_per_frame && format.mFramesPerPacket == 1;
}

bool OutputFrameCount(const AudioBufferList* output_data,
                      EQRouterOutputLayout layout,
                      size_t* out_frame_count) {
    if (!output_data || !out_frame_count) return false;
    if (layout == EQRouterOutputLayoutInterleavedStereo) {
        const AudioBuffer& buffer = output_data->mBuffers[0];
        if (!buffer.mData || buffer.mDataByteSize % (sizeof(float) * kChannels) != 0) {
            return false;
        }
        *out_frame_count = buffer.mDataByteSize / (sizeof(float) * kChannels);
        return true;
    }
    if (layout == EQRouterOutputLayoutNonInterleavedStereo) {
        const AudioBuffer& left = output_data->mBuffers[0];
        const AudioBuffer& right = output_data->mBuffers[1];
        if (!left.mData || !right.mData || left.mDataByteSize % sizeof(float) != 0 ||
            right.mDataByteSize % sizeof(float) != 0) {
            return false;
        }
        const size_t left_frames = left.mDataByteSize / sizeof(float);
        const size_t right_frames = right.mDataByteSize / sizeof(float);
        if (left_frames != right_frames) return false;
        *out_frame_count = left_frames;
        return true;
    }
    return false;
}

void ZeroOutputFrames(AudioBufferList* output_data,
                      EQRouterOutputLayout layout,
                      size_t first_frame,
                      size_t frame_count) {
    if (layout == EQRouterOutputLayoutInterleavedStereo) {
        float* output = static_cast<float*>(output_data->mBuffers[0].mData);
        for (size_t frame = first_frame; frame < frame_count; ++frame) {
            output[frame * kChannels + 0] = 0.0f;
            output[frame * kChannels + 1] = 0.0f;
        }
        return;
    }
    float* left = static_cast<float*>(output_data->mBuffers[0].mData);
    float* right = static_cast<float*>(output_data->mBuffers[1].mData);
    for (size_t frame = first_frame; frame < frame_count; ++frame) {
        left[frame] = 0.0f;
        right[frame] = 0.0f;
    }
}

OSStatus OutputCallback(AudioObjectID /*inDevice*/,
                        const AudioTimeStamp* /*inNow*/,
                        const AudioBufferList* /*inInputData*/,
                        const AudioTimeStamp* /*inInputTime*/,
                        AudioBufferList* outOutputData,
                        const AudioTimeStamp* /*inOutputTime*/,
                        void* inClientData) {
    Ring* ring = static_cast<Ring*>(inClientData);
    if (!ring || !outOutputData) return noErr;

    const EQRouterOutputLayout layout = EQRouter_ClassifyOutputLayout(outOutputData);
    if (layout == EQRouterOutputLayoutUnsupported) {
        return kAudioHardwareUnsupportedOperationError;
    }
    size_t frame_count = 0;
    if (!OutputFrameCount(outOutputData, layout, &frame_count)) {
        return kAudioHardwareUnsupportedOperationError;
    }
    if (frame_count == 0) return noErr;

    const size_t write_pos = ring->write_pos.load(std::memory_order_acquire);
    const size_t read_pos = ring->read_pos.load(std::memory_order_relaxed);
    const size_t avail = (write_pos >= read_pos) ? (write_pos - read_pos) : 0;
    const size_t to_copy = avail < frame_count ? avail : frame_count;
    if (to_copy > 0) {
        const size_t first_index = read_pos % kRingFrames;
        const size_t first_count =
            (to_copy < kRingFrames - first_index) ? to_copy : kRingFrames - first_index;
        if (EQRouter_WriteFrames(
                ring->buffer + first_index * kChannels,
                first_count,
                outOutputData,
                0
            ) != 0) {
            return kAudioHardwareUnsupportedOperationError;
        }
        if (first_count < to_copy && EQRouter_WriteFrames(
                ring->buffer,
                to_copy - first_count,
                outOutputData,
                first_count
            ) != 0) {
            return kAudioHardwareUnsupportedOperationError;
        }
    }
    if (to_copy < frame_count) {
        ZeroOutputFrames(outOutputData, layout, to_copy, frame_count);
    }
    // The whole output cycle consumed one frame range, regardless of whether
    // CoreAudio represented its two channels as one or two buffers.
    ring->read_pos.store(read_pos + to_copy, std::memory_order_release);
    return noErr;
}

} // namespace

struct EQRouter {
    AudioObjectID device = kAudioObjectUnknown;
    AudioDeviceIOProcID ioProc = nullptr;
    bool started = false;
    Ring ring;
    // Copy of the target UID used to open this router. The watcher thread
    // compares this against the contents of the target file to decide whether
    // to swap routers on the fly. Owned by the EQRouter, lives until close.
    char target_uid[256] = {0};
};

EQRouterLifetime::EQRouterLifetime(EQRouter* initial) noexcept
    : router_(initial), users_(0) {}

EQRouter* EQRouterLifetime::acquire() noexcept {
    users_.fetch_add(1, std::memory_order_seq_cst);
    EQRouter* current = router_.load(std::memory_order_seq_cst);
    if (!current) {
        release();
    }
    return current;
}

void EQRouterLifetime::release() noexcept {
    users_.fetch_sub(1, std::memory_order_seq_cst);
}

EQRouter* EQRouterLifetime::swap(EQRouter* replacement) noexcept {
    return router_.exchange(replacement, std::memory_order_seq_cst);
}

bool EQRouterLifetime::hasRouter() const noexcept {
    return router_.load(std::memory_order_seq_cst) != nullptr;
}

void EQRouterLifetime::waitForUsers() noexcept {
    while (users_.load(std::memory_order_seq_cst) != 0) {
        sched_yield();
    }
}

extern "C" {

EQRouterOutputLayout EQRouter_ClassifyOutputLayout(const AudioBufferList* output_data) {
    if (!output_data) return EQRouterOutputLayoutUnsupported;
    if (output_data->mNumberBuffers == 1 &&
        output_data->mBuffers[0].mNumberChannels == kChannels) {
        return EQRouterOutputLayoutInterleavedStereo;
    }
    if (output_data->mNumberBuffers == kChannels &&
        output_data->mBuffers[0].mNumberChannels == 1 &&
        output_data->mBuffers[1].mNumberChannels == 1) {
        return EQRouterOutputLayoutNonInterleavedStereo;
    }
    return EQRouterOutputLayoutUnsupported;
}

int EQRouter_WriteFrames(const float* frames,
                         size_t frame_count,
                         AudioBufferList* output_data,
                         size_t output_frame_offset) {
    if (!frames || !output_data || frame_count == 0) return 1;
    const EQRouterOutputLayout layout = EQRouter_ClassifyOutputLayout(output_data);
    if (layout == EQRouterOutputLayoutUnsupported) return 1;

    if (layout == EQRouterOutputLayoutInterleavedStereo) {
        AudioBuffer& buffer = output_data->mBuffers[0];
        if (!buffer.mData || buffer.mDataByteSize % (sizeof(float) * kChannels) != 0) {
            return 1;
        }
        const size_t capacity = buffer.mDataByteSize / (sizeof(float) * kChannels);
        if (output_frame_offset > capacity || frame_count > capacity - output_frame_offset) {
            return 1;
        }
        float* output = static_cast<float*>(buffer.mData);
        for (size_t frame = 0; frame < frame_count; ++frame) {
            const size_t destination = (output_frame_offset + frame) * kChannels;
            output[destination + 0] = frames[frame * kChannels + 0];
            output[destination + 1] = frames[frame * kChannels + 1];
        }
        return 0;
    }

    AudioBuffer& leftBuffer = output_data->mBuffers[0];
    AudioBuffer& rightBuffer = output_data->mBuffers[1];
    if (!leftBuffer.mData || !rightBuffer.mData ||
        leftBuffer.mDataByteSize % sizeof(float) != 0 ||
        rightBuffer.mDataByteSize % sizeof(float) != 0) {
        return 1;
    }
    const size_t leftCapacity = leftBuffer.mDataByteSize / sizeof(float);
    const size_t rightCapacity = rightBuffer.mDataByteSize / sizeof(float);
    if (leftCapacity != rightCapacity || output_frame_offset > leftCapacity ||
        frame_count > leftCapacity - output_frame_offset) {
        return 1;
    }
    float* left = static_cast<float*>(leftBuffer.mData);
    float* right = static_cast<float*>(rightBuffer.mData);
    for (size_t frame = 0; frame < frame_count; ++frame) {
        const size_t destination = output_frame_offset + frame;
        left[destination] = frames[frame * kChannels + 0];
        right[destination] = frames[frame * kChannels + 1];
    }
    return 0;
}

EQRouter* EQRouter_OpenWithError(const char* target_uid, EQRouterOpenError* out_error) {
    if (out_error) *out_error = EQRouterOpenErrorNone;
    EQR_log("EQRouter_Open: target_uid=%s", target_uid ? target_uid : "(null)");
    if (!target_uid || target_uid[0] == '\0') {
        if (out_error) *out_error = EQRouterOpenErrorInvalidTarget;
        return nullptr;
    }
    AudioObjectID device = FindDeviceByUID(target_uid);
    EQR_log("  FindDeviceByUID → AudioObjectID=%u", device);
    if (device == kAudioObjectUnknown) {
        EQR_log("  FAIL: device not found for UID");
        if (out_error) *out_error = EQRouterOpenErrorDeviceNotFound;
        return nullptr;
    }
    if (!SupportsFloat32StereoOutput(device)) {
        EQR_log("  FAIL: target is not packed Float32 stereo");
        if (out_error) *out_error = EQRouterOpenErrorUnsupportedFormat;
        return nullptr;
    }

    EQRouter* router = new (std::nothrow) EQRouter();
    if (!router) {
        EQR_log("  FAIL: failed to allocate EQRouter");
        if (out_error) *out_error = EQRouterOpenErrorAllocationFailed;
        return nullptr;
    }
    router->device = device;

    OSStatus status = AudioDeviceCreateIOProcID(
        device, OutputCallback, &router->ring, &router->ioProc
    );
    EQR_log("  AudioDeviceCreateIOProcID → status=%d ioProc=%p",
            (int)status, (void*)router->ioProc);
    if (status != noErr || !router->ioProc) {
        if (out_error) *out_error = EQRouterOpenErrorCreateIOProcFailed;
        delete router;
        return nullptr;
    }
    status = AudioDeviceStart(device, router->ioProc);
    EQR_log("  AudioDeviceStart → status=%d", (int)status);
    if (status != noErr) {
        if (out_error) *out_error = EQRouterOpenErrorStartFailed;
        AudioDeviceDestroyIOProcID(device, router->ioProc);
        delete router;
        return nullptr;
    }
    router->started = true;
    strncpy(router->target_uid, target_uid, sizeof(router->target_uid) - 1);
    EQR_log("  OK: router started on device %u", device);
    return router;
}

void EQRouter_PublishReadyStatus(const char* target_uid) {
    WriteRouterStatus("ready", target_uid, 0);
}

void EQRouter_PublishFailureStatus(const char* target_uid, int reason_code) {
    WriteRouterStatus("failed", target_uid, reason_code);
}

const char* EQRouter_TargetUID(EQRouter* router) {
    return router ? router->target_uid : "";
}

uint32_t EQRouter_TargetDevice(EQRouter* router) {
    return router ? static_cast<uint32_t>(router->device) : kAudioObjectUnknown;
}

void EQRouter_Push(EQRouter* router, const float* frames, size_t n_frames) {
    if (!router || !frames || n_frames == 0) return;
    Ring& ring = router->ring;

    const size_t write_pos = ring.write_pos.load(std::memory_order_relaxed);
    size_t read_pos = ring.read_pos.load(std::memory_order_acquire);
    const size_t in_ring = (write_pos >= read_pos) ? (write_pos - read_pos) : 0;
    // If the new push would overflow the ring, advance the read pointer so
    // the oldest frames are dropped rather than blocking the IO thread.
    if (in_ring + n_frames > kRingFrames) {
        const size_t overflow = (in_ring + n_frames) - kRingFrames;
        ring.read_pos.store(read_pos + overflow, std::memory_order_relaxed);
    }
    for (size_t i = 0; i < n_frames; ++i) {
        const size_t idx = (write_pos + i) % kRingFrames;
        ring.buffer[idx * kChannels + 0] = frames[i * kChannels + 0];
        ring.buffer[idx * kChannels + 1] = frames[i * kChannels + 1];
    }
    ring.write_pos.store(write_pos + n_frames, std::memory_order_release);
}

void EQRouter_Close(EQRouter* router) {
    if (!router) return;
    if (router->started && router->ioProc) {
        AudioDeviceStop(router->device, router->ioProc);
    }
    if (router->ioProc) {
        AudioDeviceDestroyIOProcID(router->device, router->ioProc);
    }
    delete router;
}

} // extern "C"
