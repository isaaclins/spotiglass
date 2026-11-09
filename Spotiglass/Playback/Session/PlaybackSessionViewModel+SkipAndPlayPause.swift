import Foundation

@MainActor
extension PlaybackSessionViewModel {
    /// Play / pause from the bar, Space, the Playback menu, the palette or a row (#437): shows
    /// the requested state right away, then sends it after the commands before it. Before, the
    /// controls showed it only once the command came back or the player reported it. Called
    /// synchronously from the controls, so the change is on screen before any task runs.
    /// Returns the send, or `nil` when there is nothing to toggle.
    @discardableResult
    func requestTogglePlayPause() -> Task<Void, Never>? {
        guard let request = beginPlayPauseRequest() else { return nil }
        let previous = playPauseCommandTail
        let send = Task { @MainActor [weak self] in
            // One after another: a quick pause then play must reach the player in that order,
            // even when the first one waits for the player.
            await previous?.value
            await self?.sendPlayPause(request)
        }
        playPauseCommandTail = send
        return send
    }

    /// What one press asked for, and what to go back to when the player refuses it.
    struct PlayPauseRequest {
        let serial: UInt64
        let generation: PlaybackHostGeneration
        let shouldPause: Bool
        /// Through the in-app player (Spotify's Web Playback SDK) instead of an explicit
        /// pause / resume for a device whose state is read.
        let usesInAppPlayer: Bool
        /// The in-app player showed an item, so the press sends the state it asked for. Without
        /// one there is nothing to read the state from, and the press goes out as a toggle.
        let sendsRequestedState: Bool
        let stateBefore: PlaybackConnectionState
        /// What the press put on screen: what the player has once it accepts the press.
        let stateAfter: PlaybackConnectionState
        let deviceID: String?

        /// The command Spotify's page runs for this press (its `runPlayerCommand` name).
        var inAppCommand: String {
            guard sendsRequestedState else { return PlaybackBridgeCommand.togglePlay.rawValue }
            return shouldPause ? PlaybackBridgeCommand.pause.rawValue : PlaybackBridgeCommand.resume.rawValue
        }
    }

    private func beginPlayPauseRequest() -> PlayPauseRequest? {
        let shouldPause: Bool
        let usesInAppPlayer = !isPlayerStateRead
        if usesInAppPlayer {
            // Spotify's page toggles whatever it has; with nothing on screen to flip (still
            // connecting, or ready with the account's last item) the toggle goes out as is.
            shouldPause = PlaylistBrowserPlaybackHelpers.isCurrentlyPlaying(connectionState: connectionState)
        } else {
            guard Self.isPlaybackTransportReady(for: connectionState), commandDeviceID != nil else { return nil }
            if !provider.capabilities.contains(.pushesPlayerState),
               let localCommandExpectsPlaying {
                // A player without pushed state may not have confirmed the last pause, resume
                // or play yet (a new item can still show `.ready` or the previous `.paused`
                // item). Toggle what was asked for.
                shouldPause = localCommandExpectsPlaying
            } else {
                switch connectionState {
                case .playing:
                    shouldPause = true
                case .paused:
                    shouldPause = false
                case .ready, .transferring:
                    shouldPause = latestPlayerSnapshot?.isPlaying == true
                case .disconnected, .connecting, .unavailable, .error:
                    return nil
                }
            }
        }
        // Resuming is starting music too: the other service's player pauses first (#373).
        if !shouldPause {
            onWillStartPlayback?()
        }
        playPauseRequestSerial &+= 1
        let stateBefore = connectionState
        let sendsRequestedState = !usesInAppPlayer || Self.isShowingAnItem(connectionState)
        if !usesInAppPlayer, playPauseRequestsInFlight == 0 {
            playPauseConfirmedState = stateBefore
        }
        playPauseRequestsInFlight += 1
        clearRefusedPlayPause()
        if usesInAppPlayer {
            if sendsRequestedState {
                showPlayPause(shouldPause: shouldPause)
                // Spotify's page reports the new state a moment later, and may first report the
                // old one: until it has reported this press (or the wait ends) its reports keep
                // the state shown.
                expectPushedPlayState(isPlaying: !shouldPause)
            }
        } else {
            showPlayPause(shouldPause: shouldPause)
            // Reads taken before the player has the command must not undo it either.
            playPauseReadHoldUntil = clock.now.advanced(by: Self.playPauseReadHoldDuration)
            noteLocalPlaybackMutation(
                shouldSyncTransportImmediately: false,
                playExpectation: shouldPause ? .paused : .playing
            )
        }
        let request = PlayPauseRequest(
            serial: playPauseRequestSerial,
            generation: playbackHostGeneration,
            shouldPause: shouldPause,
            usesInAppPlayer: usesInAppPlayer,
            sendsRequestedState: sendsRequestedState,
            stateBefore: stateBefore,
            stateAfter: connectionState,
            deviceID: commandDeviceID
        )
        if usesInAppPlayer {
            latestInAppPlayPauseRequest = request
        }
        return request
    }

    private static func isShowingAnItem(_ state: PlaybackConnectionState) -> Bool {
        switch state {
        case .playing, .paused(.some): true
        case .paused(.none), .disconnected, .connecting, .ready, .transferring, .unavailable, .error: false
        }
    }

    /// Shows playing or paused for the item on screen, at its current position.
    private func showPlayPause(shouldPause: Bool) {
        let nowPlaying = currentNowPlaying ?? latestPlayerSnapshot?.playbackNowPlaying
        let optimisticNowPlaying = nowPlaying.map { nowPlaying in
            let position = progressAnchor?.interpolatedPositionMs(at: Date())
                ?? nowPlaying.positionMilliseconds
            return nowPlaying.with(positionMilliseconds: position)
        }
        if shouldPause {
            setConnectionState(.paused(optimisticNowPlaying))
        } else {
            setConnectionState(.playing(optimisticNowPlaying ?? fallbackNowPlaying()))
        }
    }

    private func sendPlayPause(_ request: PlayPauseRequest) async {
        defer { playPauseRequestsInFlight = max(0, playPauseRequestsInFlight - 1) }
        guard ownsPlaybackHostGeneration(request.generation), !Task.isCancelled else { return }
        if request.usesInAppPlayer {
            do {
                // Pause then play sent as two toggles can both flip the old state when the
                // page hasn't applied the first yet; the page answers before the player has.
                if request.sendsRequestedState {
                    try await provider.setInAppPlayerPlaying(!request.shouldPause)
                } else {
                    try await provider.togglePlayPause()
                }
            } catch {
                refusePlayPause(request, error: error)
            }
            return
        }
        guard let deviceID = request.deviceID else { return }
        let action = request.shouldPause ? "pause" : "resume"
        SpotiglassLog.info(.playback, "togglePlayPause remote action=\(action) deviceID=\(deviceID)")
        do {
            try await performPrioritizedControlCommand {
                if request.shouldPause {
                    try await provider.pause(deviceID: deviceID)
                } else {
                    try await provider.resume(deviceID: deviceID)
                }
            }
            guard ownsPlaybackHostGeneration(request.generation), !Task.isCancelled else { return }
            playPauseConfirmedState = request.stateAfter
            guard request.serial == playPauseRequestSerial else { return }
            // The player has it now: read it at the settle cadence until it agrees.
            noteLocalPlaybackMutation(playExpectation: request.shouldPause ? .paused : .playing)
        } catch {
            refusePlayPause(request, error: error)
        }
    }

    /// The player refused a press. A later press already decided what is shown. Otherwise the
    /// controls go back to what the player has and the bar says why; a refusal that needs you
    /// to act (sign in again, allow access, Premium) shows that error as before. What the player
    /// has is what it last confirmed: for Spotify's page its last report, for a player whose
    /// state is read the state from before the first press still on its way, moved on by every
    /// press it accepted since (an earlier press of a quick pause, play may have been refused
    /// too).
    private func refusePlayPause(_ request: PlayPauseRequest, error: Error) {
        guard ownsPlaybackHostGeneration(request.generation), !Task.isCancelled else { return }
        guard request.serial == playPauseRequestSerial else { return }
        SpotiglassLog.error(.playback, "togglePlayPause refused: \(error.localizedDescription)")
        let displayError = Self.displayError(for: error)
        localCommandExpectsPlaying = nil
        clearPushedPlayStateExpectation()
        guard Self.playPauseRefusalGoesBack(error) else {
            setConnectionState(.error(displayError))
            return
        }
        let playerState = request.usesInAppPlayer ? pageReportedPlayState : playPauseConfirmedState
        setConnectionState(playerState ?? request.stateBefore)
        showRefusedPlayPause(refusedPlayPauseLine(for: error, displayError: displayError, shouldPause: request.shouldPause))
    }

    /// The bar's line for a refused press, in place of the artist: "Couldn't pause" as the
    /// title (the line fits about two dozen characters), the reason as a sentence on hover.
    /// Spotify's display error carries the raw error detail for diagnostics
    /// (`server(statusCode: 503 …)`), which must not end up there; Apple Music's and a rate
    /// limit's are already sentences.
    private func refusedPlayPauseLine(
        for error: Error,
        displayError: PlaybackDisplayError,
        shouldPause: Bool
    ) -> PlaybackDisplayError {
        let playbackError = MusicPlaybackError.from(error)
        let reason: String
        switch (playbackError?.service, playbackError?.reason) {
        case (.appleMusic?, _), (.spotify?, .rateLimited?):
            reason = displayError.message
        default:
            reason = service == .appleMusic
                ? SpotiglassL10n.string("error.playback.appleMusic.failed")
                : SpotiglassL10n.string("error.playback.spotify.failed")
        }
        return PlaybackDisplayError(
            title: SpotiglassL10n.string(shouldPause ? "playback.refused.pause" : "playback.refused.play"),
            message: reason,
            recoveryAction: nil
        )
    }

    /// Whether a refused play / pause just goes back: everything except what only you can fix.
    static func playPauseRefusalGoesBack(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        guard let reason = MusicPlaybackError.from(error)?.reason else { return true }
        switch reason {
        case .signInExpired, .missingPermission, .subscriptionRequired:
            return false
        case .rateLimited, .network, .server, .notFound, .explicitContentRestricted, .failed:
            return true
        }
    }

    private func showRefusedPlayPause(_ error: PlaybackDisplayError) {
        refusedPlayPauseClearTask?.cancel()
        refusedPlayPause = error
        refusedPlayPauseClearTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.clock.sleep(
                until: self.clock.now.advanced(by: Self.refusedPlayPauseDisplayDuration),
                tolerance: nil
            )
            guard !Task.isCancelled else { return }
            self.refusedPlayPause = nil
        }
    }

    func clearRefusedPlayPause() {
        refusedPlayPauseClearTask?.cancel()
        refusedPlayPauseClearTask = nil
        refusedPlayPause = nil
    }

    /// Spotify's page failed to run a command. When it is the latest press's pause, resume or
    /// toggle, that press was refused: the controls go back to what the page last reported and
    /// the bar says so. A failure of an earlier press changes nothing on screen: the latest
    /// press decides, and the page's reports show what happened.
    func handleInAppPlayPauseFailure(command: String, message: String) {
        SpotiglassLog.error(.playback, "Spotify playback SDK \(command) failed: \(message)")
        guard let request = latestInAppPlayPauseRequest,
              request.serial == playPauseRequestSerial,
              request.inAppCommand == command else { return }
        refusePlayPause(request, error: MusicPlaybackError(service: .spotify, reason: .failed, detail: message))
    }

    static func isPlayPauseCommand(_ command: String) -> Bool {
        [PlaybackBridgeCommand.pause, .resume, .togglePlay].map(\.rawValue).contains(command)
    }

    private func expectPushedPlayState(isPlaying: Bool) {
        pushedPlayStateExpectations.append(isPlaying)
        pushedPlayStateExpectationTask?.cancel()
        pushedPlayStateExpectationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.pushedPlayStateExpectationTimeout)
            guard !Task.isCancelled else { return }
            self?.pushedPlayStateExpectations = []
        }
    }

    func clearPushedPlayStateExpectation() {
        pushedPlayStateExpectationTask?.cancel()
        pushedPlayStateExpectationTask = nil
        pushedPlayStateExpectations = []
    }

    /// Whether a state Spotify's page reports may be shown. While presses wait for the page,
    /// it must report them in the order they were made: a report that isn't the next one is
    /// older (or the page skipped it) and is left out, the one for an earlier press is taken
    /// off without being shown, and only the one for the last press is shown and ends the wait.
    func acceptsPushedPlayState(isPlaying: Bool) -> Bool {
        guard let next = pushedPlayStateExpectations.first else { return true }
        guard next == isPlaying else { return false }
        pushedPlayStateExpectations.removeFirst()
        guard pushedPlayStateExpectations.isEmpty else { return false }
        clearPushedPlayStateExpectation()
        return true
    }

    /// For a player whose state is read: whether this read must not end the settle window after
    /// a pause or resume. A read that still shows the old state mustn't, for up to
    /// ``playPauseReadHoldDuration`` after the press, so slow reads can't run the window out and
    /// flip the press back. A read that agrees ends the hold.
    func playPauseReadHoldsSettle(_ snapshot: MusicPlaybackSnapshot) -> Bool {
        guard let until = playPauseReadHoldUntil else { return false }
        guard clock.now < until,
              let localCommandExpectsPlaying,
              snapshot.isPlaying != localCommandExpectsPlaying else {
            playPauseReadHoldUntil = nil
            return false
        }
        return true
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
        let succeeded = await sendDeviceCommand(dispatch: dispatch) { [provider] deviceID in
            try await performPrioritizedControlCommand {
                switch kind {
                case .previous:
                    try await provider.skipToPrevious(deviceID: deviceID)
                case .next:
                    try await provider.skipToNext(deviceID: deviceID)
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
            if !provider.capabilities.contains(.pushesPlayerState) {
                // The player has moved past the item a pending play waits for,
                // so that fence would reject every read of the new item. Only
                // reads can confirm the skip; let them through.
                clearPendingPlay()
                skipLeftItemURI = dispatch.expectedPreviousURI
            }
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
