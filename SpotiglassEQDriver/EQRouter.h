#ifndef SPOTIGLASS_EQ_ROUTER_H
#define SPOTIGLASS_EQ_ROUTER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct EQRouter EQRouter;

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

// Tear down the router and stop forwarding.
void EQRouter_Close(EQRouter* router);

#ifdef __cplusplus
}
#endif

#endif
