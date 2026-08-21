import Foundation

@MainActor
extension PlaybackSessionViewModel {
    func seek(to milliseconds: Int) async {
        enqueueSeek(milliseconds: milliseconds)
    }

    func clearPendingSeek() {
        queuedSeek = nil
        coalescedSeek = nil
        pendingSeek = nil
        pendingSeekDeadline = nil
    }

    /// Records the authoritative track that owns the seek state. A new track
    /// invalidates every optimistic seek belonging to the previous owner.
    func updateSeekOwnership(from state: PlaybackConnectionState) {
        switch state {
        case let .playing(nowPlaying):
            guard let trackURI = SpotifyPlayableURI.canonical(nowPlaying.uri) else { return }
            updateSeekOwnership(trackURI: trackURI)
        case let .paused(nowPlaying):
            guard let nowPlaying,
                  let trackURI = SpotifyPlayableURI.canonical(nowPlaying.uri) else { return }
            updateSeekOwnership(trackURI: trackURI)
        case .disconnected, .connecting, .ready, .transferring, .unavailable, .error:
            return
        }
    }

    /// Keeps the optimistic seek position visible until Spotify catches up.
    func applyPendingSeekSuppression(to nowPlaying: PlaybackNowPlaying?) -> PlaybackNowPlaying? {
        guard let pendingSeek else {
            return nowPlaying
        }
        guard pendingSeek.owner == seekOwnershipKey else {
            clearPendingSeek()
            return nowPlaying
        }
        if let deadline = pendingSeekDeadline, clock.now >= deadline {
            clearPendingSeek()
            return nowPlaying
        }
        guard let nowPlaying else {
            return nil
        }
        if abs(nowPlaying.positionMilliseconds - pendingSeek.milliseconds) <= seekMatchToleranceMilliseconds {
            clearPendingSeek()
            return nowPlaying
        }
        return nowPlaying.with(positionMilliseconds: pendingSeek.milliseconds)
    }

    private func updateSeekOwnership(trackURI: String) {
        guard seekOwnershipKey.hostGeneration != playbackHostGeneration
            || seekOwnershipKey.trackURI != trackURI else { return }
        cancelSeekDispatch()
        seekOwnershipKey = PlaybackSeekOwnershipKey(
            hostGeneration: playbackHostGeneration,
            trackURI: trackURI,
            trackGeneration: seekOwnershipKey.trackGeneration &+ 1
        )
        clearPendingSeek()
        lastSentSeek = nil
        failedSeekOwnershipKey = nil
    }

    private func enqueueSeek(milliseconds: Int) {
        let normalized = normalizedSeekMilliseconds(milliseconds)
        let intent = PlaybackSeekIntent(milliseconds: normalized, owner: seekOwnershipKey)
        if queuedSeek == nil {
            queuedSeek = intent
        } else {
            coalescedSeek = intent
        }
        pendingSeek = intent
        pendingSeekDeadline = clock.now.advanced(by: pendingSeekTimeout)
        failedSeekOwnershipKey = nil
        applyOptimisticSeekPosition(normalized)
        scheduleSeekDispatchIfNeeded()
    }

    func cancelSeekDispatch() {
        seekDispatchSerial &+= 1
        seekDispatchTask?.cancel()
        seekDispatchTask = nil
    }

    private func scheduleSeekDispatchIfNeeded() {
        guard seekDispatchTask == nil else { return }
        seekDispatchSerial &+= 1
        let serial = seekDispatchSerial
        seekDispatchTask = Task { [weak self] in
            await self?.runSeekDispatchLoop(serial: serial)
        }
    }

    private func runSeekDispatchLoop(serial: UInt64) async {
        defer { finishSeekDispatch(serial: serial) }
        while !Task.isCancelled {
            guard let intent = queuedSeek else {
                return
            }
            queuedSeek = nil

            guard intent.owner == seekOwnershipKey else {
                continue
            }
            if let lastSentSeek,
               lastSentSeek.owner == intent.owner,
               abs(intent.milliseconds - lastSentSeek.milliseconds) < seekDeduplicationWindowMilliseconds {
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

            guard intent.owner == seekOwnershipKey else {
                continue
            }
            lastSeekSentInstant = clock.now
            if await sendSeekCommand(intent) {
                guard intent.owner == seekOwnershipKey else { continue }
                lastSentSeek = intent
            }
            promoteCoalescedSeekIfNeeded()
        }
    }

    private func finishSeekDispatch(serial: UInt64) {
        guard serial == seekDispatchSerial else { return }
        seekDispatchTask = nil
        if queuedSeek != nil {
            scheduleSeekDispatchIfNeeded()
        }
    }

    private func promoteCoalescedSeekIfNeeded() {
        guard queuedSeek == nil, let coalescedSeek else { return }
        self.coalescedSeek = nil
        guard coalescedSeek.owner == seekOwnershipKey else { return }
        queuedSeek = coalescedSeek
    }

    private func sendSeekCommand(_ intent: PlaybackSeekIntent) async -> Bool {
        guard intent.owner == seekOwnershipKey else { return false }
        guard let commandDeviceID else {
            failSeek(intent, with: Self.playbackDeviceReconnectRequiredError())
            return false
        }
        do {
            try await performPrioritizedControlCommand {
                try await playbackAPI.seek(to: intent.milliseconds, deviceID: commandDeviceID)
            }
            guard intent.owner == seekOwnershipKey, !Task.isCancelled else { return false }
            return true
        } catch {
            guard intent.owner == seekOwnershipKey else { return false }
            failSeek(intent, with: Self.displayError(for: error))
            return false
        }
    }

    private func failSeek(_ intent: PlaybackSeekIntent, with error: PlaybackDisplayError) {
        guard intent.owner == seekOwnershipKey else { return }
        clearPendingSeek()
        failedSeekOwnershipKey = intent.owner
        setConnectionState(.error(error))
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
