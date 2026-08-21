import Foundation

@MainActor
extension PlaybackSessionViewModel {
    func play(uri: String) async {
        guard let commandDeviceID else {
            SpotiglassLog.error(.playback, "play(uri:) aborted: no command device. uri=\(uri)")
            setConnectionState(.error(Self.playbackDeviceNotReadyError()))
            return
        }

        let generation = playbackHostGeneration
        guard ownsPlaybackHostGeneration(generation), !Task.isCancelled else { return }
        SpotiglassLog.info(.playback, "play(uri:) entry uri=\(uri) deviceID=\(commandDeviceID) currentURI=\(currentNowPlayingURI ?? "<nil>") hasTransferred=\(hasTransferredPlaybackToCurrentDevice)")

        let commandKey = PlayCommandKey.singleURI(deviceID: commandDeviceID, uri: uri)
        guard let dispatch = beginPlayCommandDispatchIfNeeded(for: commandKey) else {
            SpotiglassLog.info(.playback, "play(uri:) deduped uri=\(uri)")
            return
        }
        activePlaylistID = nil
        beginPendingPlay(uri: uri, dispatch: dispatch)

        do {
            try await performPrioritizedControlCommand {
                try await ensurePlaybackTransferredIfNeeded(deviceID: commandDeviceID)
                try await playbackAPI.play(uri: uri, deviceID: commandDeviceID)
            }
            SpotiglassLog.info(.playback, "play(uri:) API ok uri=\(uri)")
            guard ownsPlaybackHostGeneration(generation), !Task.isCancelled,
                  isPlayCommandDispatchCurrent(dispatch) else {
                SpotiglassLog.info(.playback, "play(uri:) superseded after API uri=\(uri)")
                return
            }
            noteLocalPlaybackMutation(shouldSyncTransportImmediately: false)
            if let optimisticNowPlaying = optimisticNowPlaying(for: uri) {
                setConnectionState(.playing(optimisticNowPlaying.with(positionMilliseconds: 0)))
            }
            if !isRemotePlaybackActive {
                try await webCommander.send(.playURI, payload: ["uri": uri])
            }
            finalizePlayCommandDispatchIfCurrent(dispatch)
        } catch {
            SpotiglassLog.error(.playback, "play(uri:) failed uri=\(uri) error=\(error)")
            guard ownsPlaybackHostGeneration(generation), !Task.isCancelled,
                  isPlayCommandDispatchCurrent(dispatch) else { return }
            clearPendingPlay(ifOwnedBy: dispatch.id)
            setConnectionState(.error(Self.displayError(for: error)))
            finalizePlayCommandDispatchIfCurrent(dispatch)
        }
    }

    func play(contextURI: String) async {
        guard let commandDeviceID else {
            setConnectionState(.error(Self.playbackDeviceNotReadyError()))
            return
        }

        let generation = playbackHostGeneration
        guard ownsPlaybackHostGeneration(generation), !Task.isCancelled else { return }
        let commandKey = PlayCommandKey.contextURI(deviceID: commandDeviceID, contextURI: contextURI)
        guard let dispatch = beginPlayCommandDispatchIfNeeded(for: commandKey) else { return }
        activePlaylistID = nil
        beginPendingContextPlay(dispatch: dispatch)

        do {
            try await performPrioritizedControlCommand {
                try await ensurePlaybackTransferredIfNeeded(deviceID: commandDeviceID)
                try await playbackAPI.play(contextURI: contextURI, deviceID: commandDeviceID)
            }
            guard ownsPlaybackHostGeneration(generation), !Task.isCancelled,
                  isPlayCommandDispatchCurrent(dispatch) else { return }
            noteLocalPlaybackMutation(shouldSyncTransportImmediately: false)
            if !isRemotePlaybackActive {
                try await webCommander.send(.playURI, payload: ["uri": contextURI])
            }
            finalizePlayCommandDispatchIfCurrent(dispatch)
        } catch {
            guard ownsPlaybackHostGeneration(generation), !Task.isCancelled,
                  isPlayCommandDispatchCurrent(dispatch) else { return }
            clearPendingPlay(ifOwnedBy: dispatch.id)
            setConnectionState(.error(Self.displayError(for: error)))
            finalizePlayCommandDispatchIfCurrent(dispatch)
        }
    }

    func playFromPlaylist(clickedURI: String, playableURIs: [String], playlistID: String? = nil) async {
        guard let commandDeviceID else {
            SpotiglassLog.error(.playback, "playFromPlaylist aborted: no command device. clickedURI=\(clickedURI)")
            setConnectionState(.error(Self.playbackDeviceNotReadyError()))
            return
        }

        let generation = playbackHostGeneration
        guard ownsPlaybackHostGeneration(generation), !Task.isCancelled else { return }
        SpotiglassLog.info(.playback, "playFromPlaylist entry clickedURI=\(clickedURI) playlistID=\(playlistID ?? "<nil>") playableCount=\(playableURIs.count) currentURI=\(currentNowPlayingURI ?? "<nil>") hasTransferred=\(hasTransferredPlaybackToCurrentDevice)")

        guard let startIndex = playableURIs.firstIndex(of: clickedURI) else {
            SpotiglassLog.info(.playback, "playFromPlaylist: clicked URI not in list, falling back to single-URI play. clickedURI=\(clickedURI)")
            await play(uri: clickedURI)
            return
        }

        let queue = Array(playableURIs[startIndex...])
        guard !queue.isEmpty else {
            SpotiglassLog.info(.playback, "playFromPlaylist: sliced queue is empty, falling back to single-URI play. clickedURI=\(clickedURI)")
            await play(uri: clickedURI)
            return
        }

        let commandKey = PlayCommandKey.uriQueue(
            deviceID: commandDeviceID,
            headURI: clickedURI,
            queueCount: queue.count
        )
        guard let dispatch = beginPlayCommandDispatchIfNeeded(for: commandKey) else {
            SpotiglassLog.info(.playback, "playFromPlaylist deduped clickedURI=\(clickedURI) queueCount=\(queue.count)")
            return
        }
        activePlaylistID = playlistID
        beginPendingPlay(uri: clickedURI, dispatch: dispatch)

        do {
            try await performPrioritizedControlCommand {
                try await ensurePlaybackTransferredIfNeeded(deviceID: commandDeviceID)
                try await playbackAPI.play(uris: queue, deviceID: commandDeviceID)
            }
            SpotiglassLog.info(.playback, "playFromPlaylist API ok clickedURI=\(clickedURI) queueCount=\(queue.count)")
            guard ownsPlaybackHostGeneration(generation), !Task.isCancelled,
                  isPlayCommandDispatchCurrent(dispatch) else {
                SpotiglassLog.info(.playback, "playFromPlaylist superseded after API clickedURI=\(clickedURI)")
                return
            }
            noteLocalPlaybackMutation(shouldSyncTransportImmediately: false)
            if let optimisticNowPlaying = optimisticNowPlaying(for: clickedURI) {
                setConnectionState(.playing(optimisticNowPlaying.with(positionMilliseconds: 0)))
            }
            if !isRemotePlaybackActive {
                try await webCommander.send(.playURI, payload: ["uri": clickedURI])
            }
            finalizePlayCommandDispatchIfCurrent(dispatch)
        } catch {
            SpotiglassLog.error(.playback, "playFromPlaylist failed clickedURI=\(clickedURI) error=\(error)")
            guard ownsPlaybackHostGeneration(generation), !Task.isCancelled,
                  isPlayCommandDispatchCurrent(dispatch) else { return }
            clearPendingPlay(ifOwnedBy: dispatch.id)
            setConnectionState(.error(Self.displayError(for: error)))
            finalizePlayCommandDispatchIfCurrent(dispatch)
        }
    }

    private func beginPendingPlay(uri: String, dispatch: PlayCommandDispatch) {
        beginPendingPlayTransition(
            ownerID: dispatch.id,
            kind: .uri(expectedURI: uri)
        )
    }

    private func beginPendingContextPlay(dispatch: PlayCommandDispatch) {
        var staleURIs = pendingPlayTransition?.supersededURIs ?? []
        if let currentNowPlayingURI {
            staleURIs.insert(currentNowPlayingURI)
        }
        beginPendingPlayTransition(
            ownerID: dispatch.id,
            kind: .context(staleURIs: staleURIs)
        )
    }

    private func beginPendingPlayTransition(
        ownerID: UInt64?,
        kind: PendingPlayTransition.Kind
    ) {
        pendingPlayTransition = PendingPlayTransition(
            ownerID: ownerID,
            hostGeneration: playbackHostGeneration,
            kind: kind,
            deadline: clock.now.advanced(by: pendingPlayURITimeout),
            firstContextURI: nil
        )
    }

    func clearPendingPlay() {
        pendingPlayTransition = nil
    }

    func clearPendingPlay(ifOwnedBy ownerID: UInt64) {
        guard pendingPlayTransition?.ownerID == ownerID else { return }
        pendingPlayTransition = nil
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
        guard var transition = pendingPlayTransition else {
            return false
        }
        guard transition.hostGeneration == playbackHostGeneration else {
            pendingPlayTransition = nil
            return false
        }
        if clock.now >= transition.deadline {
            pendingPlayTransition = nil
            return false
        }
        guard let eventURI = nowPlaying?.uri else {
            return false
        }

        switch transition.kind {
        case let .uri(expectedURI):
            if eventURI == expectedURI {
                pendingPlayTransition = nil
                return false
            }
            return true
        case let .context(staleURIs):
            // A context play has no first-track URI or command ID in its SDK
            // event. Reject identities already known to belong to a
            // superseded transition, then admit the first URI that cannot be
            // ruled out. A context supersession before the predecessor emitted
            // a URI remains ambiguous because the SDK supplies no command ID.
            if staleURIs.contains(eventURI) {
                return true
            }
            if transition.firstContextURI == nil {
                transition.firstContextURI = eventURI
                pendingPlayTransition = transition
            }
            return false
        }
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
