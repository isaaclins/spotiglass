import Foundation

@MainActor
extension PlaybackSessionViewModel {
    func seek(to milliseconds: Int) async {
        enqueueSeek(milliseconds: milliseconds)
    }

    func clearPendingSeek() {
        queuedSeekPositionMilliseconds = nil
        coalescedSeekPositionMilliseconds = nil
        pendingSeekDisplayPositionMilliseconds = nil
        pendingSeekDeadline = nil
    }

    /// Keeps the optimistic seek position visible until Spotify catches up.
    func applyPendingSeekSuppression(to nowPlaying: PlaybackNowPlaying?) -> PlaybackNowPlaying? {
        guard let expectedPosition = pendingSeekDisplayPositionMilliseconds else {
            return nowPlaying
        }
        if let deadline = pendingSeekDeadline, clock.now >= deadline {
            clearPendingSeek()
            return nowPlaying
        }
        guard let nowPlaying else {
            return nil
        }
        if let incomingURI = nowPlaying.uri,
           let currentURI = currentNowPlaying?.uri,
           incomingURI != currentURI {
            clearPendingSeek()
            return nowPlaying
        }
        if abs(nowPlaying.positionMilliseconds - expectedPosition) <= seekMatchToleranceMilliseconds {
            clearPendingSeek()
            return nowPlaying
        }
        return nowPlaying.with(positionMilliseconds: expectedPosition)
    }

    private func enqueueSeek(milliseconds: Int) {
        let normalized = normalizedSeekMilliseconds(milliseconds)
        if queuedSeekPositionMilliseconds == nil {
            queuedSeekPositionMilliseconds = normalized
        } else {
            coalescedSeekPositionMilliseconds = normalized
        }
        pendingSeekDisplayPositionMilliseconds = normalized
        pendingSeekDeadline = clock.now.advanced(by: pendingSeekTimeout)
        applyOptimisticSeekPosition(normalized)
        scheduleSeekDispatchIfNeeded()
    }

    private func scheduleSeekDispatchIfNeeded() {
        guard seekDispatchTask == nil else { return }
        seekDispatchTask = Task { [weak self] in
            await self?.runSeekDispatchLoop()
        }
    }

    private func runSeekDispatchLoop() async {
        defer { seekDispatchTask = nil }
        while !Task.isCancelled {
            guard let target = queuedSeekPositionMilliseconds else {
                return
            }
            queuedSeekPositionMilliseconds = nil

            if let lastSentPosition = lastSentSeekPositionMilliseconds,
               abs(target - lastSentPosition) < seekDeduplicationWindowMilliseconds {
                continue
            }

            if let lastSeekSentInstant {
                let nextEligibleInstant = lastSeekSentInstant.advanced(by: seekRateLimitInterval)
                if clock.now < nextEligibleInstant {
                    do {
                        try await clock.sleep(until: nextEligibleInstant, tolerance: .milliseconds(20))
                    } catch {
                        return
                    }
                }
            }

            lastSeekSentInstant = clock.now
            if await sendSeekCommand(milliseconds: target) {
                lastSentSeekPositionMilliseconds = target
            }
            if queuedSeekPositionMilliseconds == nil, let coalescedTarget = coalescedSeekPositionMilliseconds {
                queuedSeekPositionMilliseconds = coalescedTarget
                coalescedSeekPositionMilliseconds = nil
            }
        }
    }

    private func sendSeekCommand(milliseconds: Int) async -> Bool {
        guard let deviceID else {
            setConnectionState(.error(Self.playbackDeviceReconnectRequiredError()))
            return false
        }
        do {
            try await performPrioritizedControlCommand {
                try await playbackAPI.seek(to: milliseconds, deviceID: deviceID)
            }
            return true
        } catch {
            setConnectionState(.error(Self.displayError(for: error)))
            return false
        }
    }

    private func normalizedSeekMilliseconds(_ milliseconds: Int) -> Int {
        let raw = max(0, milliseconds)
        guard let nowPlaying = currentNowPlaying else { return raw }
        guard nowPlaying.durationMilliseconds > 0 else { return raw }
        return min(raw, nowPlaying.durationMilliseconds)
    }

    private func applyOptimisticSeekPosition(_ milliseconds: Int) {
        switch connectionState {
        case let .playing(nowPlaying):
            setConnectionState(.playing(nowPlaying.with(positionMilliseconds: milliseconds)))
        case let .paused(nowPlaying):
            if let nowPlaying {
                setConnectionState(.paused(nowPlaying.with(positionMilliseconds: milliseconds)))
            }
        case .disconnected, .connecting, .ready, .transferring, .unavailable, .error:
            break
        }
    }
}
