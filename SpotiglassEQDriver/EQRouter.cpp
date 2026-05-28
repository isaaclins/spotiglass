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
    // OutputCallback-only counters; the target device's IO thread is the
    // single reader/writer of these. Used by the diagnostic log to surface
    // underruns when downstream (e.g. Bluetooth) drains the ring faster than
    // DoIOOperation can fill it.
    uint64_t cb_count = 0;
    uint64_t underrun_total = 0;
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

OSStatus OutputCallback(AudioObjectID /*inDevice*/,
                        const AudioTimeStamp* /*inNow*/,
                        const AudioBufferList* /*inInputData*/,
                        const AudioTimeStamp* /*inInputTime*/,
                        AudioBufferList* outOutputData,
                        const AudioTimeStamp* /*inOutputTime*/,
                        void* inClientData) {
    Ring* ring = static_cast<Ring*>(inClientData);
    if (!ring || !outOutputData) return noErr;

    ring->cb_count++;
    const bool should_log = (ring->cb_count == 1) || (ring->cb_count % 50 == 0);

    for (UInt32 b = 0; b < outOutputData->mNumberBuffers; ++b) {
        AudioBuffer& buf = outOutputData->mBuffers[b];
        if (!buf.mData) continue;
        float* out = static_cast<float*>(buf.mData);
        UInt32 channels = buf.mNumberChannels;
        if (channels == 0) continue;
        UInt32 frames = buf.mDataByteSize / (sizeof(float) * channels);

        const size_t write_pos = ring->write_pos.load(std::memory_order_acquire);
        size_t read_pos = ring->read_pos.load(std::memory_order_relaxed);
        const size_t avail = (write_pos >= read_pos) ? (write_pos - read_pos) : 0;
        UInt32 to_copy = static_cast<UInt32>(avail < frames ? avail : frames);

        for (UInt32 i = 0; i < to_copy; ++i) {
            const size_t idx = (read_pos + i) % kRingFrames;
            const float L = ring->buffer[idx * kChannels + 0];
            const float R = ring->buffer[idx * kChannels + 1];
            if (channels >= 2) {
                out[i * channels + 0] = L;
                out[i * channels + 1] = R;
                for (UInt32 c = 2; c < channels; ++c) out[i * channels + c] = 0.0f;
            } else {
                out[i * channels + 0] = 0.5f * (L + R);
            }
        }
        for (UInt32 i = to_copy; i < frames; ++i) {
            for (UInt32 c = 0; c < channels; ++c) {
                out[i * channels + c] = 0.0f;
            }
        }
        ring->read_pos.store(read_pos + to_copy, std::memory_order_release);

        const UInt32 underrun = frames - to_copy;
        ring->underrun_total += underrun;
        if (should_log) {
            EQR_log("OutputCB[%llu] buf=%u ch=%u req=%u avail=%zu copied=%u underrun=%u underrun_total=%llu",
                    (unsigned long long)ring->cb_count, (unsigned)b, (unsigned)channels,
                    (unsigned)frames, avail, (unsigned)to_copy,
                    (unsigned)underrun, (unsigned long long)ring->underrun_total);
        }
    }
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

extern "C" {

EQRouter* EQRouter_Open(const char* target_uid) {
    EQR_log("EQRouter_Open: target_uid=%s", target_uid ? target_uid : "(null)");
    AudioObjectID device = FindDeviceByUID(target_uid);
    EQR_log("  FindDeviceByUID → AudioObjectID=%u", device);
    if (device == kAudioObjectUnknown) {
        EQR_log("  FAIL: device not found for UID");
        return nullptr;
    }

    EQRouter* router = new (std::nothrow) EQRouter();
    if (!router) {
        EQR_log("  FAIL: failed to allocate EQRouter");
        return nullptr;
    }
    router->device = device;

    OSStatus status = AudioDeviceCreateIOProcID(
        device, OutputCallback, &router->ring, &router->ioProc
    );
    EQR_log("  AudioDeviceCreateIOProcID → status=%d ioProc=%p",
            (int)status, (void*)router->ioProc);
    if (status != noErr || !router->ioProc) {
        delete router;
        return nullptr;
    }
    status = AudioDeviceStart(device, router->ioProc);
    EQR_log("  AudioDeviceStart → status=%d", (int)status);
    if (status != noErr) {
        AudioDeviceDestroyIOProcID(device, router->ioProc);
        delete router;
        return nullptr;
    }
    router->started = true;
    strncpy(router->target_uid, target_uid, sizeof(router->target_uid) - 1);
    EQR_log("  OK: router started on device %u", device);
    return router;
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
