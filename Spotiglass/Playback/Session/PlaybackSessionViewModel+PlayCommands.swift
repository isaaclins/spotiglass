import Foundation

@MainActor
extension PlaybackSessionViewModel {
    func play(uri: String) async {
        guard let deviceID else {
            setConnectionState(.error(Self.playbackDeviceNotReadyError()))
            return
        }

        activePlaylistID = nil
        let commandKey = PlayCommandKey.singleURI(deviceID: deviceID, uri: uri)
        guard let dispatch = beginPlayCommandDispatchIfNeeded(for: commandKey) else { return }
        beginPendingPlay(uri: uri)

        do {
            try await performPrioritizedControlCommand {
                try await ensurePlaybackTransferredIfNeeded(deviceID: deviceID)
                try await playbackAPI.play(uri: uri, deviceID: deviceID)
            }
            guard isPlayCommandDispatchCurrent(dispatch) else { return }
            noteLocalPlaybackMutation(shouldSyncTransportImmediately: false)
            if let optimisticNowPlaying = optimisticNowPlaying(for: uri) {
                setConnectionState(.playing(optimisticNowPlaying.with(positionMilliseconds: 0)))
            }
            try await webCommander.send(.playURI, payload: ["uri": uri])
            finalizePlayCommandDispatchIfCurrent(dispatch)
        } catch {
            guard isPlayCommandDispatchCurrent(dispatch) else { return }
            clearPendingPlay()
            setConnectionState(.error(Self.displayError(for: error)))
            finalizePlayCommandDispatchIfCurrent(dispatch)
        }
    }

    func play(contextURI: String) async {
        guard let deviceID else {
            setConnectionState(.error(Self.playbackDeviceNotReadyError()))
            return
        }

        activePlaylistID = nil
        let commandKey = PlayCommandKey.contextURI(deviceID: deviceID, contextURI: contextURI)
        guard let dispatch = beginPlayCommandDispatchIfNeeded(for: commandKey) else { return }

        do {
            try await performPrioritizedControlCommand {
                try await ensurePlaybackTransferredIfNeeded(deviceID: deviceID)
                try await playbackAPI.play(contextURI: contextURI, deviceID: deviceID)
            }
            guard isPlayCommandDispatchCurrent(dispatch) else { return }
            noteLocalPlaybackMutation(shouldSyncTransportImmediately: false)
            try await webCommander.send(.playURI, payload: ["uri": contextURI])
            finalizePlayCommandDispatchIfCurrent(dispatch)
        } catch {
            guard isPlayCommandDispatchCurrent(dispatch) else { return }
            setConnectionState(.error(Self.displayError(for: error)))
            finalizePlayCommandDispatchIfCurrent(dispatch)
        }
    }

    func playFromPlaylist(clickedURI: String, playableURIs: [String], playlistID: String? = nil) async {
        guard let deviceID else {
            setConnectionState(.error(Self.playbackDeviceNotReadyError()))
            return
        }

        guard let startIndex = playableURIs.firstIndex(of: clickedURI) else {
            await play(uri: clickedURI)
            return
        }

        let queue = Array(playableURIs[startIndex...])
        guard !queue.isEmpty else {
            await play(uri: clickedURI)
            return
        }

        activePlaylistID = playlistID
        let commandKey = PlayCommandKey.uriQueue(
            deviceID: deviceID,
            headURI: clickedURI,
            queueCount: queue.count
        )
        guard let dispatch = beginPlayCommandDispatchIfNeeded(for: commandKey) else { return }
        beginPendingPlay(uri: clickedURI)

        do {
            try await performPrioritizedControlCommand {
                try await ensurePlaybackTransferredIfNeeded(deviceID: deviceID)
                try await playbackAPI.play(uris: queue, deviceID: deviceID)
            }
            guard isPlayCommandDispatchCurrent(dispatch) else { return }
            noteLocalPlaybackMutation(shouldSyncTransportImmediately: false)
            if let optimisticNowPlaying = optimisticNowPlaying(for: clickedURI) {
                setConnectionState(.playing(optimisticNowPlaying.with(positionMilliseconds: 0)))
            }
            try await webCommander.send(.playURI, payload: ["uri": clickedURI])
            finalizePlayCommandDispatchIfCurrent(dispatch)
        } catch {
            guard isPlayCommandDispatchCurrent(dispatch) else { return }
            clearPendingPlay()
            setConnectionState(.error(Self.displayError(for: error)))
            finalizePlayCommandDispatchIfCurrent(dispatch)
        }
    }

    func beginPendingPlay(uri: String) {
        pendingPlayURI = uri
        pendingPlayURIDeadline = clock.now.advanced(by: pendingPlayURITimeout)
    }

    func clearPendingPlay() {
        pendingPlayURI = nil
        pendingPlayURIDeadline = nil
    }

    func beginPlayCommandDispatchIfNeeded(for key: PlayCommandKey) -> PlayCommandDispatch? {
        playCommandAttemptedCount += 1

        if inFlightPlayCommandKey == key {
            playCommandDedupedCount += 1
            return nil
        }

        if
            lastDispatchedPlayCommandKey == key,
            let lastInstant = lastDispatchedPlayCommandInstant,
            clock.now < lastInstant.advanced(by: playCommandDedupeWindow)
        {
            playCommandDedupedCount += 1
            return nil
        }

        if let inFlightPlayCommandKey, inFlightPlayCommandKey != key {
            playCommandSupersededCount += 1
        }

        playCommandSequence &+= 1
        let dispatch = PlayCommandDispatch(id: playCommandSequence, key: key)
        inFlightPlayCommandID = dispatch.id
        inFlightPlayCommandKey = key
        lastDispatchedPlayCommandKey = key
        lastDispatchedPlayCommandInstant = clock.now
        playCommandSentCount += 1
        return dispatch
    }

    func isPlayCommandDispatchCurrent(_ dispatch: PlayCommandDispatch) -> Bool {
        inFlightPlayCommandID == dispatch.id && inFlightPlayCommandKey == dispatch.key
    }

    func finalizePlayCommandDispatchIfCurrent(_ dispatch: PlayCommandDispatch) {
        guard isPlayCommandDispatchCurrent(dispatch) else { return }
        inFlightPlayCommandID = nil
        inFlightPlayCommandKey = nil
    }

    /// Returns true when an incoming SDK `state_changed` event should be
    /// dropped because we are still waiting for the user-requested track to
    /// take effect. Allows matching events through, lets the timeout window
    /// fall back gracefully, and lets nil-track teardown events through so
    /// the SDK can still report errors / device loss while a play is pending.
    func shouldSuppressStaleStateChange(nowPlaying: PlaybackNowPlaying?) -> Bool {
        guard let pending = pendingPlayURI else {
            return false
        }
        if let deadline = pendingPlayURIDeadline, clock.now >= deadline {
            clearPendingPlay()
            return false
        }
        guard let eventURI = nowPlaying?.uri else {
            return false
        }
        if eventURI == pending {
            clearPendingPlay()
            return false
        }
        return true
    }

    func optimisticNowPlaying(for uri: String) -> PlaybackNowPlaying? {
        switch connectionState {
        case let .playing(nowPlaying), let .paused(.some(nowPlaying)):
            return nowPlaying.uri == uri ? nowPlaying : nil
        case .paused(.none), .disconnected, .connecting, .ready, .transferring, .unavailable, .error:
            return nil
        }
    }
}
