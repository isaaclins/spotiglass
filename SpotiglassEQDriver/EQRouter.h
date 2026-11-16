#ifndef SPOTIGLASS_EQ_ROUTER_H
#define SPOTIGLASS_EQ_ROUTER_H

#include <CoreAudio/AudioHardware.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct EQRouter EQRouter;

typedef enum EQRouterOutputLayout {
    EQRouterOutputLayoutUnsupported = 0,
    EQRouterOutputLayoutInterleavedStereo = 1,
    EQRouterOutputLayoutNonInterleavedStereo = 2
} EQRouterOutputLayout;

typedef enum EQRouterOpenError {
    EQRouterOpenErrorNone = 0,
    EQRouterOpenErrorInvalidTarget = 1,
    EQRouterOpenErrorDeviceNotFound = 2,
    EQRouterOpenErrorUnsupportedFormat = 3,
    EQRouterOpenErrorAllocationFailed = 4,
    EQRouterOpenErrorCreateIOProcFailed = 5,
    EQRouterOpenErrorStartFailed = 6
} EQRouterOpenError;

// Classify the output layout supplied to the target IOProc. Only packed
// Float32 stereo is supported by the router payload: one two-channel buffer
// or two one-channel buffers.
EQRouterOutputLayout EQRouter_ClassifyOutputLayout(const AudioBufferList* output_data);

// Copy a contiguous range of interleaved stereo Float32 frames into the
// target layout. The write is allocation-free and advances no router state;
// callers that consume a ring can invoke it for each contiguous ring segment.
// Returns 0 on success and nonzero when the layout or buffer sizes are invalid.
int EQRouter_WriteFrames(const float* frames,
                         size_t frame_count,
                         AudioBufferList* output_data,
                         size_t output_frame_offset);

// Open a router that forwards interleaved float32 stereo frames to the
// CoreAudio output device with the given UID. Returns NULL on failure and
// reports a machine-readable reason for the host's readiness status file.
EQRouter* EQRouter_OpenWithError(const char* target_uid, EQRouterOpenError* out_error);

// Publish the result of the asynchronous open worker for the Swift host. The
// status file is atomically replaced and is keyed by target UID, so stale
// results for an older target cannot be mistaken for readiness of a new one.
void EQRouter_PublishReadyStatus(const char* target_uid);
void EQRouter_PublishFailureStatus(const char* target_uid, int reason_code);

// Push interleaved stereo Float32 frames from the EQ device's IO callback
// into the router's lock-free ring (see EQRouterRing_Push).
void EQRouter_Push(EQRouter* router, const float* frames, size_t n_frames);

// Frames the router's ring has thrown away (overrun) or played as silence
// after it first had sound (underrun), since the router opened.
uint64_t EQRouter_DroppedFrames(EQRouter* router);
uint64_t EQRouter_SilentFrames(EQRouter* router);

// Returns the UID the router is currently forwarding to. Buffer is owned by
// the router and stable until the router is closed. Used by the watcher
// thread to detect target changes without re-opening the device.
const char* EQRouter_TargetUID(EQRouter* router);

// Returns the CoreAudio AudioObjectID of the device the router currently
// forwards to (0 / kAudioObjectUnknown when the router is null or closed).
// Used by the volume-control mirror to read / write the target device's
// kAudioDevicePropertyVolumeScalar without re-resolving its UID.
uint32_t EQRouter_TargetDevice(EQRouter* router);

// Tear down the router and stop forwarding.
void EQRouter_Close(EQRouter* router);

#ifdef __cplusplus
}

#include <atomic>

// 16384 stereo frames: ~340 ms at 48 kHz of room. The consumer keeps the fill
// near kEQRouterRingTargetFill (~43 ms at 48 kHz), so the extra room only
// matters when one side stalls.
constexpr size_t kEQRouterRingFrames = 16384;
constexpr size_t kEQRouterRingTargetFill = 2048;
constexpr size_t kEQRouterRingFillTolerance = 256;
constexpr double kEQRouterRingFillSmoothing = 0.01;

/// The single-producer / single-consumer ring between the EQ device's IO
/// callback (producer, EQRouterRing_Push) and the target device's IOProc
/// (consumer, EQRouterRing_Pull). Only the consumer moves read_pos.
struct EQRouterRing {
    float buffer[kEQRouterRingFrames * 2] = {};
    std::atomic<size_t> read_pos{0};
    std::atomic<size_t> write_pos{0};
    /// Set by a producer that overran the ring: where the consumer should
    /// resume reading.
    std::atomic<size_t> trim_to{0};
    // Consumer-only state.
    bool priming = true;
    double average_fill = 0.0;
    bool has_last_frame = false;
    float last_frame[2] = {0.0f, 0.0f};
    // Counters for diagnostics and tests.
    std::atomic<uint64_t> dropped_frames{0};
    std::atomic<uint64_t> silent_frames{0};
    std::atomic<uint64_t> slipped_frames{0};
};

extern "C" {
void EQRouterRing_Reset(EQRouterRing* ring);
// Producer side. Overrunning the ring loses the oldest frames and asks the
// consumer to start over at the target fill.
void EQRouterRing_Push(EQRouterRing* ring, const float* frames, size_t n_frames);
// Consumer side: fills one output cycle. Returns nonzero when the output
// layout is unsupported.
int EQRouterRing_Pull(EQRouterRing* ring, AudioBufferList* output_data);
}

#include <atomic>

/// Atomic pointer publication with a non-blocking reader lease. Render and
/// worker callbacks acquire a lease before loading the router pointer; the
/// swapping thread exchanges the pointer and waits off the realtime path
/// before closing the retired router.
class EQRouterLifetime {
public:
    explicit EQRouterLifetime(EQRouter* initial = nullptr) noexcept;

    EQRouter* acquire() noexcept;
    void release() noexcept;
    EQRouter* swap(EQRouter* replacement) noexcept;
    bool hasRouter() const noexcept;
    void waitForUsers() noexcept;

private:
    static_assert(std::atomic<EQRouter*>::is_always_lock_free,
                  "router pointer publication must be lock-free");
    static_assert(std::atomic<uint32_t>::is_always_lock_free,
                  "router lease counter must be lock-free");

    std::atomic<EQRouter*> router_;
    std::atomic<uint32_t> users_;
};
#endif

#endif
