import Foundation

@MainActor
extension PlaybackSessionViewModel {
    func toggleShuffle() async {
        guard let deviceID else {
            setConnectionState(.error(PlaybackDisplayError(title: "Playback device unavailable", message: "Reconnect playback before using controls.", recoveryAction: .reconnect)))
            return
        }
        let target = !shuffleEnabled
        shuffleEnabled = target
        let mutationVersion = nextShuffleMutationVersion()
        setPendingShuffle(enabled: target)

        // Avoid writes when the target is already confirmed from Spotify transport.
        if lastConfirmedShuffleEnabled == target {
            clearPendingShuffle()
            return
        }
        // Avoid duplicate writes while the same target is already in flight.
        if inFlightShuffleTarget == target {
            return
        }
        // Coalesce rapid toggles to a single follow-up write target.
        if inFlightShuffleTarget != nil {
            queuedShuffleTarget = target
            return
        }

        var nextTarget: Bool? = target
        var nextMutationVersion: UInt64 = mutationVersion
        while let requestedTarget = nextTarget {
            inFlightShuffleTarget = requestedTarget
            do {
                try await performPrioritizedControlCommand {
                    try await playbackAPI.setShuffle(enabled: requestedTarget, deviceID: deviceID)
                }
                lastConfirmedShuffleEnabled = requestedTarget
                scheduleTransportSyncAfterShuffleToggle(minimumMutationVersion: nextMutationVersion)
            } catch {
                inFlightShuffleTarget = nil
                queuedShuffleTarget = nil
                clearPendingShuffle()
                let fallback = lastConfirmedShuffleEnabled ?? !requestedTarget
                if shuffleEnabled == requestedTarget {
                    shuffleEnabled = fallback
                }
                setConnectionState(.error(Self.displayError(for: error)))
                return
            }
            inFlightShuffleTarget = nil

            guard let queuedTarget = queuedShuffleTarget else {
                return
            }
            queuedShuffleTarget = nil
            if lastConfirmedShuffleEnabled == queuedTarget {
                if shuffleEnabled != queuedTarget {
                    shuffleEnabled = queuedTarget
                }
                clearPendingShuffle()
                return
            }
            nextTarget = queuedTarget
            nextMutationVersion = nextShuffleMutationVersion()
            setPendingShuffle(enabled: queuedTarget)
            shuffleEnabled = queuedTarget
        }
    }

    func cycleRepeat() async {
        guard let deviceID else {
            setConnectionState(.error(PlaybackDisplayError(title: "Playback device unavailable", message: "Reconnect playback before using controls.", recoveryAction: .reconnect)))
            return
        }
        let nextMode = repeatMode.next
        repeatMode = nextMode
        desiredRepeatMode = nextMode
        setPendingRepeat(mode: nextMode)
        await flushDesiredRepeatWrites(deviceID: deviceID)
    }

    func setPendingRepeat(mode: SpotifyRepeatMode) {
        pendingRepeatMode = mode
        pendingRepeatDeadline = clock.now.advanced(by: pendingRepeatTimeout)
    }

    func setPendingShuffle(enabled: Bool) {
        pendingShuffleEnabled = enabled
        pendingShuffleDeadline = clock.now.advanced(by: pendingShuffleTimeout)
    }

    func clearPendingShuffle() {
        pendingShuffleEnabled = nil
        pendingShuffleDeadline = nil
    }

    func clearPendingRepeat() {
        pendingRepeatMode = nil
        pendingRepeatDeadline = nil
    }

    /// Applies shuffle from Spotify transport while suppressing stale reads
    /// during a short optimistic-shuffle window.
    func applyTransportShuffleEnabled(_ transportShuffle: Bool, minimumMutationVersion: UInt64?) {
        if let minimumMutationVersion, minimumMutationVersion < shuffleMutationVersion {
            return
        }
        guard let expected = pendingShuffleEnabled else {
            shuffleEnabled = transportShuffle
            lastConfirmedShuffleEnabled = transportShuffle
            return
        }
        if transportShuffle == expected {
            shuffleEnabled = transportShuffle
            lastConfirmedShuffleEnabled = transportShuffle
            clearPendingShuffle()
            return
        }
        if let deadline = pendingShuffleDeadline, clock.now < deadline {
            return
        }
        shuffleEnabled = transportShuffle
        lastConfirmedShuffleEnabled = transportShuffle
        clearPendingShuffle()
    }

    /// Applies repeat from Spotify transport while suppressing stale reads
    /// during a short optimistic-repeat window.
    func applyTransportRepeatMode(_ transportMode: SpotifyRepeatMode) {
        guard let expected = pendingRepeatMode else {
            repeatMode = transportMode
            confirmedRepeatMode = transportMode
            return
        }
        if transportMode == expected {
            repeatMode = transportMode
            confirmedRepeatMode = transportMode
            clearPendingRepeat()
            return
        }
        if let deadline = pendingRepeatDeadline, clock.now < deadline {
            return
        }
        repeatMode = transportMode
        confirmedRepeatMode = transportMode
        clearPendingRepeat()
    }

    private func flushDesiredRepeatWrites(deviceID: String) async {
        guard !repeatWriteInFlight else { return }

        while let targetMode = desiredRepeatMode {
            if shouldSkipRepeatWrite(targetMode: targetMode) {
                if desiredRepeatMode == targetMode {
                    desiredRepeatMode = nil
                }
                continue
            }

            await sleepIfInsideRepeatWriteWindow()
            repeatWriteInFlight = true

            do {
                try await performPrioritizedControlCommand {
                    try await playbackAPI.setRepeat(mode: targetMode, deviceID: deviceID)
                }
                lastRepeatWriteAt = clock.now
                lastRepeatCommandedMode = targetMode
                if desiredRepeatMode == targetMode {
                    desiredRepeatMode = nil
                }
                scheduleTransportSyncAfterRepeatToggle()
            } catch {
                if desiredRepeatMode == targetMode {
                    desiredRepeatMode = nil
                }
                clearPendingRepeat()
                if repeatMode == targetMode {
                    repeatMode = confirmedRepeatMode
                }
                setConnectionState(.error(Self.displayError(for: error)))
            }

            repeatWriteInFlight = false
        }
    }

    private func shouldSkipRepeatWrite(targetMode: SpotifyRepeatMode) -> Bool {
        if targetMode == confirmedRepeatMode {
            if repeatWriteInFlight {
                return false
            }
            if let lastCommanded = lastRepeatCommandedMode, lastCommanded != targetMode {
                return false
            }
            if let pendingMode = pendingRepeatMode, pendingMode != targetMode {
                return false
            }
            return true
        }
        if targetMode == pendingRepeatMode, targetMode == lastRepeatCommandedMode {
            return true
        }
        return false
    }

    private func sleepIfInsideRepeatWriteWindow() async {
        guard let lastRepeatWriteAt else { return }
        let nextEligibleWriteAt = lastRepeatWriteAt.advanced(by: repeatWriteMinInterval)
        guard clock.now < nextEligibleWriteAt else { return }
        do {
            try await clock.sleep(until: nextEligibleWriteAt, tolerance: .milliseconds(20))
        } catch {
            // Cancellation means this pacing wait can be safely abandoned.
        }
    }

    private func scheduleTransportSyncAfterRepeatToggle() {
        repeatSyncTask?.cancel()
        repeatSyncTask = Task { [weak self] in
            guard let delay = self?.postRepeatSyncDelay else { return }
            try? await Task.sleep(for: delay)
            guard let self else { return }
            await self.syncTransportFromSpotify()
        }
    }

    private func scheduleTransportSyncAfterShuffleToggle(minimumMutationVersion: UInt64) {
        shuffleSyncTask?.cancel()
        shuffleSyncTask = Task { [weak self] in
            guard let delay = self?.postShuffleSyncDelay else { return }
            try? await Task.sleep(for: delay)
            guard let self else { return }
            await self.syncTransportFromSpotify(minimumShuffleMutationVersion: minimumMutationVersion)
        }
    }

    private func nextShuffleMutationVersion() -> UInt64 {
        shuffleMutationVersion &+= 1
        return shuffleMutationVersion
    }
}
