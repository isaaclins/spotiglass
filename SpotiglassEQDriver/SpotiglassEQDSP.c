// SpotiglassEQDriver / SpotiglassEQDSP.c
//
// The 10-band biquad cascade. NOT using vDSP_biquadm here because:
//   - vDSP's biquad API allocates a setup struct, which we can't do on the
//     RT thread; reallocating across IO cycles would burn cycles and risk
//     paging. (vDSP_biquadm_CreateSetup is documented as non-RT-safe.)
//   - A hand-rolled transposed direct-form-II inner loop is ~12 SLOC,
//     auto-vectorises well, and keeps the state easy to inspect. The
//     compiler emits NEON instructions on Apple Silicon for the multiply-
//     adds.
//   - Latency: the cascade introduces 0 samples of delay between input
//     and output (the biquad's group delay shows up only as phase, not
//     additional samples).

#include "SpotiglassEQDSP.h"

#include <math.h>
#include <string.h>

void EQDSP_Reset(EQDSPState* state) {
    if (!state) return;
    memset(state, 0, sizeof(*state));
}

/// Single biquad step, transposed direct-form-II:
///
///     y = b0*x + z1
///     z1' = b1*x - a1*y + z2
///     z2' = b2*x - a2*y
///
/// This form is numerically stable for fixed-point cascades and keeps the
/// state z1/z2 history consistent across coefficient updates.
static inline float biquadStep(float x,
                               float b0, float b1, float b2,
                               float a1, float a2,
                               EQBiquadState* st) {
    const float y = b0 * x + st->z1;
    st->z1 = b1 * x - a1 * y + st->z2;
    st->z2 = b2 * x - a2 * y;
    return y;
}

void EQDSP_Apply(EQDSPState* state,
                 const EQCoefficientFrame* frame,
                 float* buffer,
                 size_t frameCount) {
    if (!state || !buffer || frameCount == 0) return;

    // No published frame yet AND no cached frame -> emit unchanged buffer.
    if (!frame && !state->hasCached) return;

    // Refresh cached frame when a new one is provided.
    if (frame) {
        state->cachedFrame = *frame;
        state->hasCached = 1;
    }
    const EQCoefficientFrame* active = state->hasCached ? &state->cachedFrame : frame;
    if (!active) return;

    const float preamp = active->preampLinear;
    const int bandsEnabled = (active->enabledMask != 0);

    if (!bandsEnabled) {
        // EQ disabled: apply only preamp. The preamp is still useful for the
        // user (e.g. -2 dB on a Loudness preset they've kept set even with
        // the master toggle off).
        for (size_t i = 0; i < frameCount * SPOTIGLASS_EQ_CHANNEL_COUNT; ++i) {
            buffer[i] *= preamp;
        }
        return;
    }

    // Cascade through all 10 bands per channel.
    for (size_t i = 0; i < frameCount; ++i) {
        for (int ch = 0; ch < SPOTIGLASS_EQ_CHANNEL_COUNT; ++ch) {
            float x = buffer[i * SPOTIGLASS_EQ_CHANNEL_COUNT + ch] * preamp;
            for (int band = 0; band < SPOTIGLASS_EQ_BAND_COUNT; ++band) {
                const size_t base = (size_t)band * SPOTIGLASS_EQ_COEFFS_PER_BAND;
                x = biquadStep(
                    x,
                    active->bandCoeffs[base + 0],
                    active->bandCoeffs[base + 1],
                    active->bandCoeffs[base + 2],
                    active->bandCoeffs[base + 3],
                    active->bandCoeffs[base + 4],
                    &state->bandState[ch][band]
                );
            }
            buffer[i * SPOTIGLASS_EQ_CHANNEL_COUNT + ch] = x;
        }
    }
}
