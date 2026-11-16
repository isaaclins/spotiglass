#ifndef SPOTIGLASS_EQ_DEVICE_STATE_H
#define SPOTIGLASS_EQ_DEVICE_STATE_H

// The EQ device's bookkeeping that doesn't touch Core Audio, kept apart so the
// driver tests run it as it is (#590).

#include <atomic>
#include <stdint.h>

#include "EQClock.h"

/// Which rate the EQ device should run at, and when to ask coreaudiod for it.
///
/// While sound is forwarded, the EQ device follows its target's rate (when it
/// offers that rate) and takes no other. With nothing forwarded, a rate a
/// client set is applied. Requests go through coreaudiod
/// (RequestDeviceConfigurationChange), which may never perform or abort one,
/// so a request still pending after kRequestTicks watcher ticks is asked again.
struct EQRateFollower {
    static constexpr uint32_t kRequestTicks = 10;

    std::atomic<uint32_t> requested{0};
    std::atomic<uint32_t> target{0};
    std::atomic<uint32_t> client{0};
    uint32_t requestedTicks = 0;  // watcher thread only

    /// One watcher tick. `current` is the EQ device's rate; `hasTarget` says
    /// whether a router forwards, to a device at `targetRate`. Returns the rate
    /// to request now, or 0.
    uint32_t tick(uint32_t current, bool hasTarget, double targetRate) {
        if (requested.load(std::memory_order_acquire) != 0) {
            if (++requestedTicks > kRequestTicks) {
                requestedTicks = 0;
                requested.store(0, std::memory_order_release);
            }
        } else {
            requestedTicks = 0;
        }
        uint32_t want = 0;
        if (!hasTarget) {
            target.store(0, std::memory_order_release);
            want = client.exchange(0, std::memory_order_acq_rel);
        } else {
            want = static_cast<uint32_t>(
                EQClock_MatchingRate(targetRate, kEQSupportedSampleRates, kEQNumSupportedSampleRates));
            target.store(want, std::memory_order_release);
            client.store(0, std::memory_order_release);
        }
        if (want == 0 || want == current) return 0;
        if (requested.exchange(want, std::memory_order_acq_rel) == want) return 0;
        requestedTicks = 0;
        return want;
    }

    /// coreaudiod refused, aborted or performed the request: the next tick
    /// decides afresh.
    void settled() { requested.store(0, std::memory_order_release); }

    /// A client sets `rate` (SetPropertyData). Returns false when the EQ device
    /// can't take it: not a rate it offers, or not its target's while sound is
    /// forwarded (another app fighting the watcher would restart IO each time).
    bool clientSets(double rate) {
        if (EQClock_MatchingRate(rate, kEQSupportedSampleRates, kEQNumSupportedSampleRates) == 0.0) return false;
        const uint32_t forwardedRate = target.load(std::memory_order_acquire);
        if (forwardedRate != 0) return static_cast<uint32_t>(rate) == forwardedRate;
        client.store(static_cast<uint32_t>(rate), std::memory_order_release);
        return true;
    }
};

/// StartIO and StopIO come per client; the device runs while at least one
/// client has IO running. Call with the plugin's state lock held.
struct EQIOClients {
    uint32_t count = 0;
    /// Whether this start is the first (the device starts).
    bool start() { return count++ == 0; }
    /// Whether this stop is the last (the device stops). A stop without a start is ignored.
    bool stop() {
        if (count == 0) return false;
        return --count == 0;
    }
};

#endif
