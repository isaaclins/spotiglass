import Foundation

/// Pure transport-poll scheduling rules for ``PlaybackSessionViewModel`` (testable without timers).
enum TransportPollScheduling {
    static func transportPollingKey(
        for state: PlaybackConnectionState,
        resolvedTrackURI: (String?) -> String
    ) -> String {
        switch state {
        case .disconnected:
            "disconnected"
        case .connecting:
            "connecting"
        case .ready(let deviceID):
            "ready:\(deviceID)"
        case .transferring(let deviceID):
            "transferring:\(deviceID)"
        case .playing(let nowPlaying), .paused(.some(let nowPlaying)):
            "track:\(resolvedTrackURI(nowPlaying.uri))"
        case .paused(.none):
            "paused-empty"
        case .unavailable(let message):
            "unavailable:\(message)"
        case .error(let error):
            "error:\(error.title)"
        }
    }

    static func shouldRunTransportPolling(
        isAppActive: Bool,
        deviceID: String?,
        localMutationSettleTicksRemaining: Int,
        state: PlaybackConnectionState
    ) -> Bool {
        guard isAppActive else { return false }
        if localMutationSettleTicksRemaining > 0 { return true }
        guard deviceID != nil else { return false }
        switch state {
        case .playing, .paused, .ready, .transferring:
            return true
        case .disconnected, .connecting, .unavailable, .error:
            return false
        }
    }

    struct PollDelayInputs {
        var now: ContinuousClock.Instant
        var transportRateLimitedUntil: ContinuousClock.Instant?
        var localMutationSettleTicksRemaining: Int
        var transportTransientErrorCount: Int
        var hasLatestPlayerSnapshot: Bool
        var isPlaybackActiveForPolling: Bool
        var connectionState: PlaybackConnectionState
    }

    static func pollDelay(for inputs: PollDelayInputs) -> Duration {
        if let rateLimitedUntil = inputs.transportRateLimitedUntil {
            if rateLimitedUntil > inputs.now {
                return max(rateLimitedUntil - inputs.now, .seconds(1))
            }
            return .seconds(15)
        }
        if inputs.localMutationSettleTicksRemaining > 0 {
            return .seconds(1)
        }
        if inputs.transportTransientErrorCount > 0 {
            let seconds = min(1 << inputs.transportTransientErrorCount, 16)
            return .seconds(seconds)
        }
        if !inputs.hasLatestPlayerSnapshot {
            return .seconds(20)
        }
        if inputs.isPlaybackActiveForPolling {
            return .seconds(2)
        }
        switch inputs.connectionState {
        case .paused:
            return .seconds(8)
        case .ready, .transferring:
            return .seconds(20)
        case .playing:
            return .seconds(2)
        case .disconnected, .connecting, .unavailable, .error:
            return .seconds(30)
        }
    }
}
