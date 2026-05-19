import Foundation

@MainActor
extension PlaybackSessionViewModel {
    func restartTransportPollingIfNeeded() {
        transportPollTask?.cancel()
        transportPollTask = nil
        guard shouldRunTransportPolling else { return }
        transportPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let delay = await MainActor.run { self.currentTransportPollDelay() }
                try? await Task.sleep(for: delay)
                let shouldPoll = await MainActor.run { self.shouldRunTransportPolling }
                guard shouldPoll else { break }
                await self.syncTransportFromSpotify()
            }
        }
    }

    private var shouldRunTransportPolling: Bool {
        guard isAppActive else { return false }
        if localMutationSettleTicksRemaining > 0 { return true }
        guard deviceID != nil else { return false }
        switch connectionState {
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
