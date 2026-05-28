// SpotiglassEQDriver / SpotiglassEQDSP.h
//
// The real-time DSP heart of the HAL plugin: applies a 10-band biquad cascade
// (transposed direct-form-II) to an output buffer of interleaved stereo
// 32-bit floats. Coefficients come from a `EQCoefficientFrame` snapshot
// produced by `EQCoefficientReader_Snapshot`.
//
// Threading: every function is called only from the CoreAudio IO callback.
// Allocations and syscalls are forbidden here.

#ifndef SPOTIGLASS_EQ_DSP_H
#define SPOTIGLASS_EQ_DSP_H

#include "EQCoefficientFrame.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Per-band biquad state. Each channel gets its own state instance so the
/// cascade is bit-identical across L/R unless the user has asked for it not
/// to be (Spotiglass currently keeps both channels in lockstep).
typedef struct {
    float z1;
    float z2;
} EQBiquadState;

#define SPOTIGLASS_EQ_CHANNEL_COUNT 2

/// All persistent DSP state the plugin keeps between IO cycles.
typedef struct {
    EQBiquadState bandState[SPOTIGLASS_EQ_CHANNEL_COUNT][SPOTIGLASS_EQ_BAND_COUNT];
    /// Last frame we successfully read; used as the active filter set when
    /// the reader reports a torn read or the writer hasn't published yet.
    EQCoefficientFrame cachedFrame;
    int hasCached;
} EQDSPState;

/// Initialises the DSP state to passthrough.
void EQDSP_Reset(EQDSPState* state);

/// Applies the biquad cascade to `bufferStereoFloat`, in-place. `frameCount`
/// is the number of stereo frames (so the buffer has frameCount*2 samples).
///
/// `frame->enabledMask == 0` means the user disabled the EQ — the function
/// then only applies the preamp and skips the cascade entirely.
void EQDSP_Apply(EQDSPState* state,
                 const EQCoefficientFrame* frame,
                 float* bufferStereoFloat,
                 size_t frameCount);

#ifdef __cplusplus
}
#endif

#endif // SPOTIGLASS_EQ_DSP_H
