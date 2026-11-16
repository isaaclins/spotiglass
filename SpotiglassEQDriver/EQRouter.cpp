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

constexpr size_t kChannels = 2;

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
    EQRouterRing* ring = static_cast<EQRouterRing*>(inClientData);
    if (!ring || !outOutputData) return noErr;
    return EQRouterRing_Pull(ring, outOutputData) == 0 ? noErr : kAudioHardwareUnsupportedOperationError;
}

} // namespace

struct EQRouter {
    AudioObjectID device = kAudioObjectUnknown;
    AudioDeviceIOProcID ioProc = nullptr;
    bool started = false;
    EQRouterRing ring;
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
    if (!router) return;
    EQRouterRing_Push(&router->ring, frames, n_frames);
}

void EQRouter_SetRate(EQRouter* router, uint32_t rate_hz) {
    if (router && rate_hz > 0) router->ring.rate_hz.store(rate_hz, std::memory_order_relaxed);
}

uint64_t EQRouter_DroppedFrames(EQRouter* router) {
    return router ? router->ring.dropped_frames.load(std::memory_order_relaxed) : 0;
}

uint64_t EQRouter_SilentFrames(EQRouter* router) {
    return router ? router->ring.silent_frames.load(std::memory_order_relaxed) : 0;
}

// MARK: - Ring

// The EQ device runs on the Mac's host clock and the target device on its own
// hardware clock. Even at the same nominal rate the two drift apart by a few
// parts per million, and before #590 the ring absorbed that by throwing away a
// whole IO buffer when it overflowed and playing silence when it ran dry: a
// cut every so often, and a song that sped up while frames were dropped.
//
// The consumer now keeps the ring near kRingTargetFill: it slips one frame
// (skips or repeats one) per output cycle while the averaged fill is off by
// more than kRingFillTolerance. One frame in a cycle of a few hundred is
// inaudible and corrects up to ~0.2 %, far more than clock drift. Only a ring
// that runs completely dry (the producer stopped) or completely full (the
// consumer stopped) still drops or pads, and it then starts over at the
// target fill instead of staying on the edge.

void EQRouterRing_Reset(EQRouterRing* ring) {
    if (!ring) return;
    ring->read_pos.store(0, std::memory_order_relaxed);
    ring->write_pos.store(0, std::memory_order_relaxed);
    ring->max_push.store(0, std::memory_order_relaxed);
    ring->max_pull = 0;
    ring->priming = true;
    ring->window_cycles = 0;
    ring->window_low = 0;
    ring->pending_slips = 0;
    ring->skip_window = true;
    ring->has_last_frame = false;
    ring->last_frame[0] = 0.0f;
    ring->last_frame[1] = 0.0f;
    ring->dropped_frames.store(0, std::memory_order_relaxed);
    ring->silent_frames.store(0, std::memory_order_relaxed);
    ring->slipped_frames.store(0, std::memory_order_relaxed);
}

size_t EQRouterRing_TargetFill(const EQRouterRing* ring) {
    // The low point moves in whole pushes (when a push lands just after a
    // pull instead of just before it), so it keeps a push of room above a pull.
    return ring->max_pull + ring->max_push.load(std::memory_order_relaxed) + EQRouterRing_Margin(ring);
}

size_t EQRouterRing_Margin(const EQRouterRing* ring) {
    const size_t byTime = static_cast<size_t>(ring->rate_hz.load(std::memory_order_relaxed)) * 107 / 10000;
    return byTime > kEQRouterRingFillMargin ? byTime : kEQRouterRingFillMargin;
}

void EQRouterRing_Push(EQRouterRing* ring, const float* frames, size_t n_frames) {
    if (!ring || !frames || n_frames == 0) return;
    // Never write more than half the ring at once: keep the newest frames.
    constexpr size_t kMaxPush = kEQRouterRingMaxChunk;
    if (n_frames > kMaxPush) {
        ring->dropped_frames.fetch_add(n_frames - kMaxPush, std::memory_order_relaxed);
        frames += (n_frames - kMaxPush) * kChannels;
        n_frames = kMaxPush;
    }
    if (n_frames > ring->max_push.load(std::memory_order_relaxed)) {
        ring->max_push.store(n_frames, std::memory_order_relaxed);
    }
    const size_t write_pos = ring->write_pos.load(std::memory_order_relaxed);
    const size_t read_pos = ring->read_pos.load(std::memory_order_acquire);
    const size_t in_ring = (write_pos >= read_pos) ? (write_pos - read_pos) : 0;
    if (in_ring + n_frames > kEQRouterRingFrames) {
        // The consumer isn't keeping up at all (stopped, or far off rate): the
        // unread frames this push overwrites are lost. Only the consumer moves
        // the read position; it notices the overrun from the positions.
        const size_t overwritten = in_ring + n_frames - kEQRouterRingFrames;
        ring->dropped_frames.fetch_add(overwritten < n_frames ? overwritten : n_frames,
                                       std::memory_order_relaxed);
    }
    for (size_t i = 0; i < n_frames; ++i) {
        const size_t idx = (write_pos + i) % kEQRouterRingFrames;
        ring->buffer[idx * kChannels + 0] = frames[i * kChannels + 0];
        ring->buffer[idx * kChannels + 1] = frames[i * kChannels + 1];
    }
    ring->write_pos.store(write_pos + n_frames, std::memory_order_release);
}

namespace {

void ReadRingFrame(const EQRouterRing* ring, size_t position, float* out) {
    const size_t idx = position % kEQRouterRingFrames;
    out[0] = ring->buffer[idx * kChannels + 0];
    out[1] = ring->buffer[idx * kChannels + 1];
}

void PutOutputFrame(AudioBufferList* output_data, EQRouterOutputLayout layout, size_t frame, const float* value) {
    if (layout == EQRouterOutputLayoutInterleavedStereo) {
        float* output = static_cast<float*>(output_data->mBuffers[0].mData);
        output[frame * kChannels + 0] = value[0];
        output[frame * kChannels + 1] = value[1];
        return;
    }
    static_cast<float*>(output_data->mBuffers[0].mData)[frame] = value[0];
    static_cast<float*>(output_data->mBuffers[1].mData)[frame] = value[1];
}

} // namespace

int EQRouterRing_Pull(EQRouterRing* ring, AudioBufferList* output_data) {
    if (!ring || !output_data) return 1;
    const EQRouterOutputLayout layout = EQRouter_ClassifyOutputLayout(output_data);
    if (layout == EQRouterOutputLayoutUnsupported) return 1;
    size_t frame_count = 0;
    if (!OutputFrameCount(output_data, layout, &frame_count)) return 1;
    if (frame_count == 0) return 0;

    // A pull larger than the ring allows is played as silence beyond its cap.
    if (frame_count > kEQRouterRingMaxChunk) {
        ZeroOutputFrames(output_data, layout, kEQRouterRingMaxChunk, frame_count);
        frame_count = kEQRouterRingMaxChunk;
    }
    if (frame_count > ring->max_pull) ring->max_pull = frame_count;
    const size_t target = EQRouterRing_TargetFill(ring);
    const size_t write_pos = ring->write_pos.load(std::memory_order_acquire);
    size_t read_pos = ring->read_pos.load(std::memory_order_relaxed);
    // A push raises the fill by its whole size at once, so the fill swings
    // between a low point and a push above it. Playing starts (and an overrun
    // resumes) a push above the target low point.
    const size_t push = ring->max_push.load(std::memory_order_relaxed);
    const size_t start_fill = target + push;
    // The producer overran the ring: frames older than one push before the
    // oldest slot it may be writing right now are gone or going. Start over
    // with the newest sound.
    // Checked against the largest push allowed, not the largest seen: the
    // first larger push may be landing right now.
    if (write_pos > read_pos && write_pos - read_pos > kEQRouterRingFrames - kEQRouterRingMaxChunk &&
        write_pos >= start_fill) {
        read_pos = write_pos - start_fill;
        ring->window_cycles = 0;
        ring->pending_slips = 0;
        ring->skip_window = true;
    }
    size_t avail = (write_pos >= read_pos) ? (write_pos - read_pos) : 0;

    // After running dry, wait until the start fill is back before playing
    // again, so one late producer cycle doesn't become a stutter of tiny gaps.
    if (ring->priming) {
        if (avail < start_fill) {
            ZeroOutputFrames(output_data, layout, 0, frame_count);
            if (ring->has_last_frame) {
                ring->silent_frames.fetch_add(frame_count, std::memory_order_relaxed);
            }
            ring->read_pos.store(read_pos, std::memory_order_release);
            return 0;
        }
        // Coming out of silence, so dropping what piled up meanwhile is
        // inaudible: start at exactly the start fill.
        if (avail > start_fill) {
            read_pos = write_pos - start_fill;
            avail = start_fill;
        }
        ring->priming = false;
        ring->window_cycles = 0;
        ring->pending_slips = 0;
        ring->skip_window = true;
    }

    // Steer the fill's low point, measured over a window of cycles, toward the
    // target. The low point doesn't depend on where in the push/pull sawtooth
    // a cycle happens to land, so matched clocks never slip a frame; drift is
    // made up once it moves the low point past the dead band, one frame per
    // cycle, and the window after a correction isn't judged so the correction
    // is never counted twice.
    if (ring->window_cycles == 0 || avail < ring->window_low) ring->window_low = avail;
    if (++ring->window_cycles >= kEQRouterRingWindow) {
        if (ring->pending_slips != 0) {
            // Still correcting: this window's low point is out of date.
        } else if (ring->skip_window) {
            ring->skip_window = false;
        } else {
            // Below the target risks running dry; up to a push above it is only
            // latency (where the low point settles depends on how pushes and
            // pulls interleave), so that range is left alone.
            const long error = static_cast<long>(ring->window_low) - static_cast<long>(target);
            const long deadBand = static_cast<long>(EQRouterRing_Margin(ring) / 2);
            const long above = static_cast<long>(push) + deadBand;
            if (error > above || error < -deadBand) {
                ring->pending_slips = error > 0 ? error - static_cast<long>(push / 2) : error;
                ring->skip_window = true;
            }
        }
        ring->window_cycles = 0;
    }
    size_t consume = frame_count;
    if (ring->pending_slips > 0 && avail > frame_count + 1) {
        consume = frame_count + 1; // skip one frame
        ring->pending_slips -= 1;
    } else if (ring->pending_slips < 0 && frame_count > 1) {
        consume = frame_count - 1; // repeat one frame
        ring->pending_slips += 1;
    }
    if (consume != frame_count && ring->pending_slips == 0) {
        // The correction is done: measure afresh from here.
        ring->window_cycles = 0;
        ring->skip_window = false;
    }

    // Map `frame_count` output frames onto `consume` ring frames. The slip
    // lands in the middle of the cycle; every other frame is copied as is.
    const size_t slip_at = frame_count / 2;
    size_t source = read_pos;
    size_t produced = 0;
    for (size_t frame = 0; frame < frame_count; ++frame) {
        if (consume == frame_count + 1 && frame == slip_at) {
            source += 1; // skip
        }
        if (source >= write_pos) break;
        float value[2];
        ReadRingFrame(ring, source, value);
        PutOutputFrame(output_data, layout, frame, value);
        ring->last_frame[0] = value[0];
        ring->last_frame[1] = value[1];
        ring->has_last_frame = true;
        produced = frame + 1;
        if (consume == frame_count - 1 && frame == slip_at) {
            continue; // repeat: the next output frame reads the same source frame
        }
        source += 1;
    }
    if (consume != frame_count && produced == frame_count) {
        ring->slipped_frames.fetch_add(1, std::memory_order_relaxed);
    }
    if (produced < frame_count) {
        // Ran dry: pad with silence and wait for the target fill again.
        ZeroOutputFrames(output_data, layout, produced, frame_count);
        ring->silent_frames.fetch_add(frame_count - produced, std::memory_order_relaxed);
        ring->priming = true;
    }
    ring->read_pos.store(source, std::memory_order_release);
    return 0;
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
