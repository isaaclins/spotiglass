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
        return TransportPollScheduling.shouldRunTransportPolling(
            isAppActive: isAppActive,
            deviceID: deviceID,
            localMutationSettleTicksRemaining: localMutationSettleTicksRemaining,
            state: state
        )
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
        TransportPollScheduling.transportPollingKey(for: state, resolvedTrackURI: resolvedTransportTrackURI)
    }

    func resolvedTransportTrackURI(_ uri: String?) -> String {
        if let uri, !uri.isEmpty { return uri }
        return stableTransportTrackURI ?? ""
    }

    private func currentTransportPollDelay() -> Duration {
        if let rateLimitedUntil = transportRateLimitedUntil, rateLimitedUntil <= clock.now {
            transportRateLimitedUntil = nil
        }
        return TransportPollScheduling.pollDelay(for: TransportPollScheduling.PollDelayInputs(
            now: clock.now,
            transportRateLimitedUntil: transportRateLimitedUntil,
            localMutationSettleTicksRemaining: localMutationSettleTicksRemaining,
            transportTransientErrorCount: transportTransientErrorCount,
            hasLatestPlayerSnapshot: latestPlayerSnapshot != nil,
            isPlaybackActiveForPolling: isPlaybackActiveForPolling,
            connectionState: connectionState
        ))
    }
}
