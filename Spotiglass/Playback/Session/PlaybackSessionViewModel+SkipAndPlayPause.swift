import Foundation

@MainActor
extension PlaybackSessionViewModel {
    func togglePlayPause() async {
        guard !togglePlayPauseAwaitingBridgeAck else { return }
        togglePlayPauseAwaitingBridgeAck = true
        scheduleTogglePlayPauseAckTimeout()
        do {
            try await webCommander.send(.togglePlay, payload: [:])
        } catch {
            clearTogglePlayPauseAckWait()
            setConnectionState(.error(Self.displayError(for: error)))
        }
    }

    private func scheduleTogglePlayPauseAckTimeout() {
        togglePlayPauseAckTimeoutTask?.cancel()
        togglePlayPauseAckTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.togglePlayPauseAckTimeout)
            await MainActor.run {
                self?.clearTogglePlayPauseAckWait()
            }
        }
    }

    func clearTogglePlayPauseAckWait() {
        togglePlayPauseAckTimeoutTask?.cancel()
        togglePlayPauseAckTimeoutTask = nil
        togglePlayPauseAwaitingBridgeAck = false
    }

    func previous() async {
        await dispatchSkipCommand(.previous)
    }

    func next() async {
        await dispatchSkipCommand(.next)
    }

    private enum SkipCommandKind {
        case previous
        case next
    }

    /// Serializes Web API skip POSTs from every entry point (button, hotkey,
    /// command palette row). The same gate covers both `previous` and `next` so
    /// a fast Prev → Next → Prev burst from a held hotkey, an auto-repeat
    /// firehose that slipped through, or a rage click cannot stack overlapping
    /// requests against `POST /v1/me/player/{previous,next}`.
    private func dispatchSkipCommand(_ kind: SkipCommandKind) async {
        if kind == .next {
            nextCommandAttemptedCount += 1
        }
        if isSkipCommandPending {
            if kind == .next {
                nextCommandDroppedLockoutCount += 1
            }
            return
        }
        if case .transferring = connectionState {
            return
        }
        let now = clock.now
        if kind == .next,
           let deadline = pendingSkipDeadline {
            if now < deadline {
                nextCommandDroppedLockoutCount += 1
                return
            }
            pendingSkipDeadline = nil
            pendingSkipExpectedPreviousURI = nil
            isNextCommandLockedOut = false
            nextCommandTimeoutUnlockCount += 1
        }
        if let last = lastSkipDispatchInstant,
           now < last.advanced(by: skipCommandMinimumSpacing) {
            if kind == .next {
                nextCommandDroppedDedupeCount += 1
            }
            return
        }
        lastSkipDispatchInstant = now
        isSkipCommandPending = true
        let expectedPreviousURI = currentNowPlayingURI
        await sendDeviceCommand { [playbackAPI] deviceID in
            try await performPrioritizedControlCommand {
                switch kind {
                case .previous:
                    try await playbackAPI.previous(deviceID: deviceID)
                case .next:
                    try await playbackAPI.next(deviceID: deviceID)
                }
            }
        }
        isSkipCommandPending = false
        guard connectionStateError == nil else {
            pendingSkipDeadline = nil
            pendingSkipExpectedPreviousURI = nil
            return
        }
        if kind == .next {
            pendingSkipExpectedPreviousURI = expectedPreviousURI
            pendingSkipDeadline = now.advanced(by: skipCommandLockoutTimeout)
            isNextCommandLockedOut = true
            nextCommandSentCount += 1
        }
    }

    func observeSkipAdvance(nowPlayingURI: String?) {
        guard let expectedPreviousURI = pendingSkipExpectedPreviousURI else { return }
        guard let nowPlayingURI, nowPlayingURI != expectedPreviousURI else { return }
        pendingSkipExpectedPreviousURI = nil
        pendingSkipDeadline = nil
        isNextCommandLockedOut = false
    }

    func clearPendingSkipCommand() {
        isSkipCommandPending = false
        pendingSkipExpectedPreviousURI = nil
        pendingSkipDeadline = nil
        isNextCommandLockedOut = false
    }

    private func sendDeviceCommand(action: (String) async throws -> Void) async {
        guard let deviceID else {
            setConnectionState(.error(PlaybackDisplayError(title: "Playback device unavailable", message: "Reconnect playback before using controls.", recoveryAction: .reconnect)))
            return
        }
        do {
            try await action(deviceID)
            noteLocalPlaybackMutation()
        } catch {
            setConnectionState(.error(Self.displayError(for: error)))
        }
    }
}
