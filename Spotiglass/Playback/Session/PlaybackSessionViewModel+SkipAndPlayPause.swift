import Foundation

@MainActor
extension PlaybackSessionViewModel {
    func togglePlayPause() async {
        guard !isRemotePlaybackActive else { return }
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

    /// Serializes Web API skip POSTs from every entry point (button, hotkey,
    /// command palette row). The same gate covers both `previous` and `next` so
    /// a fast Prev → Next → Prev burst from a held hotkey, an auto-repeat
    /// firehose that slipped through, or a rage click cannot stack overlapping
    /// requests against `POST /v1/me/player/{previous,next}`.
    private func dispatchSkipCommand(_ kind: SkipCommandDispatch.Kind) async {
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
            clearPendingSkipCommand()
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
        skipCommandSequence &+= 1
        let dispatch = SkipCommandDispatch(
            id: skipCommandSequence,
            hostGeneration: playbackHostGeneration,
            kind: kind,
            expectedPreviousURI: currentNowPlayingURI,
            startedAt: now
        )
        pendingSkipDispatch = dispatch
        isSkipCommandPending = true
        let succeeded = await sendDeviceCommand(dispatch: dispatch) { [playbackAPI] deviceID in
            try await performPrioritizedControlCommand {
                switch kind {
                case .previous:
                    try await playbackAPI.previous(deviceID: deviceID)
                case .next:
                    try await playbackAPI.next(deviceID: deviceID)
                }
            }
        }

        guard isCurrentSkipCommandDispatch(dispatch) else { return }
        isSkipCommandPending = false
        guard ownsPlaybackHostGeneration(dispatch.hostGeneration), !Task.isCancelled else {
            clearCurrentSkipCommand(dispatch)
            return
        }
        guard succeeded else {
            clearCurrentSkipCommand(dispatch)
            return
        }

        switch kind {
        case .previous:
            pendingSkipDispatch = nil
            isNextCommandLockedOut = pendingNextSkipLockout != nil
        case .next:
            nextCommandSentCount += 1
            guard var completedDispatch = pendingSkipDispatch else { return }
            if hasObservedSkipAdvance(completedDispatch) {
                pendingSkipDispatch = nil
                pendingNextSkipLockout = nil
                isNextCommandLockedOut = false
            } else {
                completedDispatch.lockoutDeadline = dispatch.startedAt.advanced(by: skipCommandLockoutTimeout)
                pendingSkipDispatch = nil
                pendingNextSkipLockout = completedDispatch
                isNextCommandLockedOut = true
            }
        }
    }

    func observeSkipAdvance(nowPlayingURI: String?) {
        if var dispatch = pendingSkipDispatch,
           dispatch.kind == .next,
           dispatch.hostGeneration == playbackHostGeneration,
           let nowPlayingURI
        {
            guard isSkipURIAdvance(
                expectedPreviousURI: dispatch.expectedPreviousURI,
                currentURI: nowPlayingURI
            ) else { return }
            dispatch.observedAdvance = true
            pendingSkipDispatch = dispatch
            return
        }

        guard let lockout = pendingNextSkipLockout,
              lockout.hostGeneration == playbackHostGeneration,
              let nowPlayingURI,
              lockout.lockoutDeadline != nil,
              isSkipURIAdvance(
                  expectedPreviousURI: lockout.expectedPreviousURI,
                  currentURI: nowPlayingURI
              )
        else { return }
        pendingNextSkipLockout = nil
        isNextCommandLockedOut = false
    }

    func clearPendingSkipCommand() {
        isSkipCommandPending = false
        pendingSkipDispatch = nil
        pendingNextSkipLockout = nil
        isNextCommandLockedOut = false
    }

    private func clearCurrentSkipCommand(_ dispatch: SkipCommandDispatch) {
        guard isCurrentSkipCommandDispatch(dispatch) else { return }
        pendingSkipDispatch = nil
        isSkipCommandPending = false
        isNextCommandLockedOut = pendingNextSkipLockout != nil
    }

    private func hasObservedSkipAdvance(_ dispatch: SkipCommandDispatch) -> Bool {
        dispatch.observedAdvance
            || isSkipURIAdvance(
                expectedPreviousURI: dispatch.expectedPreviousURI,
                currentURI: currentNowPlayingURI
            )
    }

    private func isSkipURIAdvance(expectedPreviousURI: String?, currentURI: String?) -> Bool {
        switch (expectedPreviousURI, currentURI) {
        case (nil, .some):
            // With no pre-request URI, an identified current URI is the only
            // observable evidence that the skip transition happened.
            true
        case let (.some(expected), .some(current)):
            current != expected
        case (_, nil):
            false
        }
    }

    private func isCurrentSkipCommandDispatch(_ dispatch: SkipCommandDispatch) -> Bool {
        pendingSkipDispatch?.id == dispatch.id
            && pendingSkipDispatch?.hostGeneration == dispatch.hostGeneration
    }

    private func sendDeviceCommand(
        dispatch: SkipCommandDispatch,
        action: (String) async throws -> Void
    ) async -> Bool {
        guard isCurrentSkipCommandDispatch(dispatch),
              ownsPlaybackHostGeneration(dispatch.hostGeneration),
              !Task.isCancelled
        else { return false }
        guard let commandDeviceID else {
            setConnectionState(.error(Self.playbackDeviceReconnectRequiredError()))
            return false
        }
        do {
            try await action(commandDeviceID)
            guard isCurrentSkipCommandDispatch(dispatch),
                  ownsPlaybackHostGeneration(dispatch.hostGeneration),
                  !Task.isCancelled
            else { return false }
            noteLocalPlaybackMutation()
            return true
        } catch {
            guard isCurrentSkipCommandDispatch(dispatch),
                  ownsPlaybackHostGeneration(dispatch.hostGeneration),
                  !Task.isCancelled
            else { return false }
            setConnectionState(.error(Self.displayError(for: error)))
            return false
        }
    }
}
