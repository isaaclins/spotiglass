#ifndef SPOTIGLASS_EQ_CLOCK_H
#define SPOTIGLASS_EQ_CLOCK_H

// The EQ device's zero timestamps (#590).
//
// coreaudiod times a device's IO cycles from the zero timestamps the driver
// reports: pairs of (sample time, host time), one per ZeroTimeStampPeriod
// frames, whose spacing tells it how fast the device runs. Before #590 the
// driver returned the samples elapsed since StartIO with the host time of
// StartIO itself, so every timestamp claimed that ever more samples had
// passed at the same instant. This follows Apple's NullAudio sample driver:
// the sample time is a whole number of periods and the host time is exactly
// when that period began on the host clock.

#include <stdint.h>

/// Every rate the EQ device offers. It follows its target's rate, so this
/// covers what output devices run at: Bluetooth headsets in call mode (8 to
/// 24 kHz) up to high-rate DACs (384 kHz).
constexpr double kEQSupportedSampleRates[] = {
    8000.0, 11025.0, 16000.0, 22050.0, 24000.0, 32000.0, 44100.0, 48000.0,
    64000.0, 88200.0, 96000.0, 176400.0, 192000.0, 352800.0, 384000.0
};
constexpr uint32_t kEQNumSupportedSampleRates =
    sizeof(kEQSupportedSampleRates) / sizeof(kEQSupportedSampleRates[0]);

constexpr uint32_t kEQZeroTimeStampPeriod = 16384;

struct EQZeroTimeStampClock {
    uint64_t anchorHostTime = 0;
    uint64_t numberOfTimeStamps = 0;
    double hostTicksPerFrame = 0.0;
};

/// Starts the timeline at `anchorHostTime`. `hostTicksPerSecond` is the host
/// clock's frequency (mach ticks per second), `sampleRate` the device's rate.
inline void EQClock_Reset(EQZeroTimeStampClock* clock,
                          uint64_t anchorHostTime,
                          double hostTicksPerSecond,
                          double sampleRate) {
    clock->anchorHostTime = anchorHostTime;
    clock->numberOfTimeStamps = 0;
    clock->hostTicksPerFrame = sampleRate > 0.0 ? hostTicksPerSecond / sampleRate : 0.0;
}

/// The latest zero timestamp at or before `nowHostTime`.
inline void EQClock_ZeroTimeStamp(EQZeroTimeStampClock* clock,
                                  uint64_t nowHostTime,
                                  double* outSampleTime,
                                  uint64_t* outHostTime) {
    const double ticksPerPeriod = clock->hostTicksPerFrame * kEQZeroTimeStampPeriod;
    if (ticksPerPeriod > 0.0) {
        // Catch up in one step if the clock wasn't asked for a while.
        while (clock->anchorHostTime +
                   static_cast<uint64_t>(static_cast<double>(clock->numberOfTimeStamps + 1) * ticksPerPeriod) <=
               nowHostTime) {
            clock->numberOfTimeStamps += 1;
        }
    }
    *outSampleTime = static_cast<double>(clock->numberOfTimeStamps) * kEQZeroTimeStampPeriod;
    *outHostTime = clock->anchorHostTime +
        static_cast<uint64_t>(static_cast<double>(clock->numberOfTimeStamps) * ticksPerPeriod);
}

/// The supported nominal rate the EQ device should run at to match a target
/// device running at `targetRate`, or 0 when the target's rate isn't one the
/// EQ device offers (it then keeps its own rate).
inline double EQClock_MatchingRate(double targetRate, const double* supported, uint32_t count) {
    for (uint32_t i = 0; i < count; ++i) {
        if (supported[i] == targetRate) return targetRate;
    }
    return 0.0;
}

#endif
