import Foundation

@MainActor
extension PlaybackSessionViewModel {
    func restartTransportPollingIfNeeded() {
        transportPollTask?.cancel()
        transportPollTask = nil
        guard shouldRunTransportPolling(for: nil) else { return }
        transportPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let delay = await MainActor.run { self.currentTransportPollDelay() }
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                let shouldPoll = await MainActor.run { self.shouldRunTransportPolling(for: nil) }
                guard shouldPoll else { break }
                await self.syncTransportFromSpotify()
            }
        }
    }

    func shouldRunTransportPolling(for state: PlaybackConnectionState? = nil) -> Bool {
        let state = state ?? connectionState
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

    private var isPlaybackActiveForPolling: Bool {
        switch connectionState {
        case .playing:
            return true
        default:
            return latestPlayerSnapshot?.isPlaying == true
        }
    }

    /// Stable key for transport poll scheduling tests and diagnostics.
    /// Ignores scrubber position and play/pause so SDK ticks do not restart polling.
    func transportPollingKey(for state: PlaybackConnectionState) -> String {
        switch state {
        case .disconnected:
            "disconnected"
        case .connecting:
            "connecting"
        case let .ready(deviceID):
            "ready:\(deviceID)"
        case let .transferring(deviceID):
            "transferring:\(deviceID)"
        case let .playing(nowPlaying), let .paused(.some(nowPlaying)):
            "track:\(resolvedTransportTrackURI(nowPlaying.uri))"
        case .paused(.none):
            "paused-empty"
        case let .unavailable(message):
            "unavailable:\(message)"
        case let .error(error):
            "error:\(error.title)"
        }
    }

    func resolvedTransportTrackURI(_ uri: String?) -> String {
        if let uri, !uri.isEmpty { return uri }
        return stableTransportTrackURI ?? ""
    }

    private func currentTransportPollDelay() -> Duration {
        if let rateLimitedUntil = transportRateLimitedUntil {
            if rateLimitedUntil > clock.now {
                return max(rateLimitedUntil - clock.now, .seconds(1))
            }
            transportRateLimitedUntil = nil
            return .seconds(15)
        }
        if localMutationSettleTicksRemaining > 0 {
            return .seconds(1)
        }
        if transportTransientErrorCount > 0 {
            let seconds = min(1 << transportTransientErrorCount, 16)
            return .seconds(seconds)
        }
        if latestPlayerSnapshot == nil {
            return .seconds(20)
        }
        if isPlaybackActiveForPolling {
            return .seconds(2)
        }
        switch connectionState {
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
