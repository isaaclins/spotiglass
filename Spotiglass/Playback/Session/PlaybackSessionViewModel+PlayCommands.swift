import Foundation

@MainActor
extension PlaybackSessionViewModel {
    func play(uri: String) async {
        guard let deviceID else {
            SpotiglassLog.error(.playback, "play(uri:) aborted: deviceID is nil. uri=\(uri)")
            setConnectionState(.error(Self.playbackDeviceNotReadyError()))
            return
        }

        SpotiglassLog.info(
            .playback,
            "play(uri:) entry uri=\(uri) deviceID=\(deviceID) currentURI=\(currentNowPlayingURI ?? "<nil>") hasTransferred=\(hasTransferredPlaybackToCurrentDevice)"
        )

        activePlaylistID = nil
        let commandKey = PlayCommandKey.singleURI(deviceID: deviceID, uri: uri)
        guard let dispatch = beginPlayCommandDispatchIfNeeded(for: commandKey) else {
            SpotiglassLog.info(.playback, "play(uri:) deduped uri=\(uri)")
            return
        }
        beginPendingPlay(uri: uri)

        do {
            try await performPrioritizedControlCommand {
                try await ensurePlaybackTransferredIfNeeded(deviceID: deviceID)
                try await playbackAPI.play(uri: uri, deviceID: deviceID)
            }
            SpotiglassLog.info(.playback, "play(uri:) API ok uri=\(uri)")
            guard isPlayCommandDispatchCurrent(dispatch) else {
                SpotiglassLog.info(.playback, "play(uri:) superseded after API uri=\(uri)")
                return
            }
            noteLocalPlaybackMutation(shouldSyncTransportImmediately: false)
            if let optimisticNowPlaying = optimisticNowPlaying(for: uri) {
                setConnectionState(.playing(optimisticNowPlaying.with(positionMilliseconds: 0)))
            }
            try await webCommander.send(.playURI, payload: ["uri": uri])
            finalizePlayCommandDispatchIfCurrent(dispatch)
        } catch {
            SpotiglassLog.error(.playback, "play(uri:) failed uri=\(uri) error=\(error)")
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
            SpotiglassLog.error(.playback, "playFromPlaylist aborted: deviceID is nil. clickedURI=\(clickedURI)")
            setConnectionState(.error(Self.playbackDeviceNotReadyError()))
            return
        }

        SpotiglassLog.info(
            .playback,
            "playFromPlaylist entry clickedURI=\(clickedURI) playlistID=\(playlistID ?? "<nil>") playableCount=\(playableURIs.count) currentURI=\(currentNowPlayingURI ?? "<nil>") hasTransferred=\(hasTransferredPlaybackToCurrentDevice)"
        )

        guard let startIndex = playableURIs.firstIndex(of: clickedURI) else {
            SpotiglassLog.info(
                .playback,
                "playFromPlaylist: clicked URI not in list, falling back to single-URI play. clickedURI=\(clickedURI)")
            await play(uri: clickedURI)
            return
        }

        let queue = Array(playableURIs[startIndex...])
        guard !queue.isEmpty else {
            SpotiglassLog.info(
                .playback,
                "playFromPlaylist: sliced queue is empty, falling back to single-URI play. clickedURI=\(clickedURI)")
            await play(uri: clickedURI)
            return
        }

        activePlaylistID = playlistID
        let commandKey = PlayCommandKey.uriQueue(
            deviceID: deviceID,
            headURI: clickedURI,
            queueCount: queue.count
        )
        guard let dispatch = beginPlayCommandDispatchIfNeeded(for: commandKey) else {
            SpotiglassLog.info(.playback, "playFromPlaylist deduped clickedURI=\(clickedURI) queueCount=\(queue.count)")
            return
        }
        beginPendingPlay(uri: clickedURI)

        do {
            try await performPrioritizedControlCommand {
                try await ensurePlaybackTransferredIfNeeded(deviceID: deviceID)
                try await playbackAPI.play(uris: queue, deviceID: deviceID)
            }
            SpotiglassLog.info(.playback, "playFromPlaylist API ok clickedURI=\(clickedURI) queueCount=\(queue.count)")
            guard isPlayCommandDispatchCurrent(dispatch) else {
                SpotiglassLog.info(.playback, "playFromPlaylist superseded after API clickedURI=\(clickedURI)")
                return
            }
            noteLocalPlaybackMutation(shouldSyncTransportImmediately: false)
            if let optimisticNowPlaying = optimisticNowPlaying(for: clickedURI) {
                setConnectionState(.playing(optimisticNowPlaying.with(positionMilliseconds: 0)))
            }
            try await webCommander.send(.playURI, payload: ["uri": clickedURI])
            finalizePlayCommandDispatchIfCurrent(dispatch)
        } catch {
            SpotiglassLog.error(.playback, "playFromPlaylist failed clickedURI=\(clickedURI) error=\(error)")
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

        if lastDispatchedPlayCommandKey == key,
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
        case .playing(let nowPlaying), .paused(.some(let nowPlaying)):
            return nowPlaying.uri == uri ? nowPlaying : nil
        case .paused(.none), .disconnected, .connecting, .ready, .transferring, .unavailable, .error:
            return nil
        }
    }
}
