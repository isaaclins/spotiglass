// SpotiglassEQDriver / EQCoefficientFrame.h
//
// Binary layout of the GUI -> HAL plugin coefficient channel. MUST stay in
// lockstep with `Spotiglass/Playback/EQCoefficients.swift` and
// `Spotiglass/Playback/EQCoefficientPublisher.swift` on the Swift side.
//
// The struct is read from a memory-mapped POSIX shared-memory backing file
// inside the HAL plugin's IO callback. Reads use a seqlock retry protocol:
//
//   1. Snapshot `sequence`. If odd, the writer is mid-update; retry next
//      cycle.
//   2. memcpy the payload into a stack-local frame.
//   3. Snapshot `sequence` again. If it changed between (1) and (3), the
//      payload may be torn; retry next cycle.
//
// All multi-byte fields are little-endian Apple Silicon / x86_64 native;
// the plugin only ever loads on the same machine that wrote the file, so
// no byte-swap is needed.

#ifndef SPOTIGLASS_EQ_COEFFICIENT_FRAME_H
#define SPOTIGLASS_EQ_COEFFICIENT_FRAME_H

#include <stdatomic.h>
#include <stdint.h>

#define SPOTIGLASS_EQ_BAND_COUNT       10
#define SPOTIGLASS_EQ_COEFFS_PER_BAND  5
#define SPOTIGLASS_EQ_COEFF_FLOATS \
    (SPOTIGLASS_EQ_BAND_COUNT * SPOTIGLASS_EQ_COEFFS_PER_BAND)

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    /// Seqlock counter. Even = stable, odd = writer is mid-update.
    /// Read via two atomic loads bracketing the payload memcpy.
    _Atomic uint64_t sequence;

    /// Multiplied with the input sample before the band cascade.
    /// Linear (already converted from dB by the GUI process).
    float preampLinear;

    /// 10 bands * 5 coefficients (b0, b1, b2, a1, a2). a0 is implicit 1.
    /// Transposed direct-form-II is the most numerically-stable choice
    /// for fixed-point cascades; the plugin uses the same form so the
    /// state z1/z2 history is consistent across rate changes.
    float bandCoeffs[SPOTIGLASS_EQ_COEFF_FLOATS];

    /// Device's active output sample rate as last seen by the GUI process.
    /// On rate change, the GUI re-derives coefficients and rewrites.
    uint32_t sampleRateHz;

    /// Bit i = band i enabled. Currently always 0xFFFF_FFFF in production;
    /// reserved for future per-band bypass without recomputing coefficients.
    uint32_t enabledMask;
} EQCoefficientFrame;

#ifdef __cplusplus
}
#endif

#endif // SPOTIGLASS_EQ_COEFFICIENT_FRAME_H
