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
// CoreAudio output device with the given UID. Returns NULL on failure.
EQRouter* EQRouter_Open(const char* target_uid);

// Push interleaved float32 stereo frames from the EQ device's IO callback
// into the router's lock-free ring. Drops oldest frames if the ring is full.
void EQRouter_Push(EQRouter* router, const float* frames, size_t n_frames);

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
