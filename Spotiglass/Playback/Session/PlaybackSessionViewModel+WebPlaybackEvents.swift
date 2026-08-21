import Foundation

@MainActor
extension PlaybackSessionViewModel {
    func handle(_ envelope: PlaybackBridgeEventEnvelope) {
        guard ownsPlaybackHostGeneration(envelope.hostGeneration) else {
            SpotiglassLog.info(.playback, "Ignoring stale SDK event generation=\(envelope.hostGeneration.rawValue) current=\(playbackHostGeneration.rawValue)")
            return
        }
        handleCurrentPlaybackEvent(envelope.event)
    }

    func handle(_ event: PlaybackBridgeEvent) {
        handle(PlaybackBridgeEventEnvelope(event: event, hostGeneration: playbackHostGeneration))
    }

    private func handleCurrentPlaybackEvent(_ event: PlaybackBridgeEvent) {
        switch event {
        case let .ready(deviceID):
            SpotiglassLog.info(.playback, "SDK ready deviceID=\(deviceID) previousDeviceID=\(self.deviceID ?? "<nil>") autoResumeOnNextReady=\(autoResumeOnNextReady)")
            if supersededSDKDeviceIDs.contains(deviceID) {
                guard self.deviceID == nil, reclaimableSDKDeviceID == deviceID else {
                    SpotiglassLog.info(.playback, "Ignoring stale SDK ready deviceID=\(deviceID)")
                    return
                }
                supersededSDKDeviceIDs.remove(deviceID)
            }
            reclaimableSDKDeviceID = nil
            let previousSDKDeviceID = self.deviceID
            let shouldRefreshTransportState = !(previousSDKDeviceID == deviceID && isTransportStateKnown)
            if shouldRefreshTransportState {
                setTransportStateKnown(false)
            }
            if let previousSDKDeviceID, previousSDKDeviceID != deviceID {
                supersededSDKDeviceIDs.insert(previousSDKDeviceID)
            }
            if previousSDKDeviceID != deviceID {
                hasTransferredPlaybackToCurrentDevice = false
            }
            self.deviceID = deviceID
            if activePlaybackDeviceID == nil || activePlaybackDeviceID == previousSDKDeviceID {
                setActivePlaybackDeviceID(deviceID)
            }
            setConnectionState(.ready(deviceID: deviceID))
            refreshTrayOutputSymbol()
            let persistedVolume = playbackVolume
            let persistedVolumeMutationVersion = shouldRefreshTransportState
                ? beginPendingPlaybackVolumeMutation(target: persistedVolume)
                : volumeMutationVersion
            let persistedVolumeSendSerial = playbackVolumeSendSerial
            let initialTransportSyncTask = shouldRefreshTransportState ? scheduleTransportSync() : nil
            let shouldAutoResume = autoResumeOnNextReady
            playbackHostAutoResumeTask?.cancel()
            playbackHostAutoResumeTask = nil
            playbackHostAutoResumeSerial &+= 1
            let autoResumeSerial = playbackHostAutoResumeSerial
            let generation = playbackHostGeneration
            playbackHostAutoResumeTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    if self.ownsPlaybackHostGeneration(generation),
                       self.playbackHostAutoResumeSerial == autoResumeSerial {
                        self.playbackHostAutoResumeTask = nil
                        if shouldAutoResume {
                            self.autoResumeOnNextReady = false
                        }
                    }
                }
                guard self.ownsPlaybackHostGeneration(generation),
                      self.playbackHostAutoResumeSerial == autoResumeSerial,
                      !Task.isCancelled else { return }
                await self.syncPlaybackVolumeToWebPlayer(
                    persistedVolume,
                    mutationVersion: persistedVolumeMutationVersion,
                    sendSerial: persistedVolumeSendSerial,
                    generation: generation
                )
                guard self.ownsPlaybackHostGeneration(generation),
                      self.playbackHostAutoResumeSerial == autoResumeSerial,
                      !Task.isCancelled else { return }
                if shouldAutoResume {
                    await self.autoResumeFromStaleSpotiglassDeviceIfNeeded(
                        targetDeviceID: deviceID,
                        initialTransportSyncTask: initialTransportSyncTask,
                        generation: generation
                    )
                }
            }
        case let .notReady(deviceID):
            SpotiglassLog.info(.playback, "SDK not_ready deviceID=\(deviceID)")
            if self.deviceID == deviceID {
                supersededSDKDeviceIDs.insert(deviceID)
                reclaimableSDKDeviceID = deviceID
            }
            guard self.deviceID == deviceID else {
                SpotiglassLog.info(.playback, "Ignoring stale SDK not_ready deviceID=\(deviceID) currentDeviceID=\(self.deviceID ?? "<nil>")")
                return
            }
            self.deviceID = nil
            setTransportStateKnown(false)
            if activePlaybackDeviceID == deviceID {
                setActivePlaybackDeviceID(nil)
            }
            hasTransferredPlaybackToCurrentDevice = false
            clearPendingSkipCommand()
            sdkNextTracks = []
            setConnectionState(.unavailable("Spotify playback device is no longer available. Reconnect playback to continue."))
            playbackHostRecoveryTask?.cancel()
            playbackHostRecoveryTask = nil
            playbackHostRecoverySerial &+= 1
            let recoverySerial = playbackHostRecoverySerial
            let generation = playbackHostGeneration
            playbackHostRecoveryTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    if self.ownsPlaybackHostGeneration(generation),
                       self.playbackHostRecoverySerial == recoverySerial {
                        self.playbackHostRecoveryTask = nil
                    }
                }
                await self.attemptPlaybackHostRecovery(cause: .notReady, generation: generation)
            }
        case let .stateChanged(nowPlaying, isPaused, nextTracks):
            let suppressed = shouldSuppressStaleStateChange(nowPlaying: nowPlaying)
            SpotiglassLog.info(.playback, "SDK state_changed nowPlayingURI=\(nowPlaying?.uri ?? "<nil>") isPaused=\(isPaused) nextCount=\(nextTracks.count) pendingPlayURI=\(pendingPlayURI ?? "<nil>") suppressed=\(suppressed)")
            observeSkipAdvance(nowPlayingURI: nowPlaying?.uri)
            if suppressed {
                return
            }
            let authoritativeState: PlaybackConnectionState = isPaused
                ? .paused(nowPlaying)
                : .playing(nowPlaying ?? fallbackNowPlaying())
            updateSeekOwnership(from: authoritativeState)
            if failedSeekOwnershipKey == seekOwnershipKey {
                return
            }
            sdkNextTracks = nextTracks
            let effectiveNowPlaying = applyPendingSeekSuppression(to: nowPlaying)
            if effectiveNowPlaying != nil, !isRemotePlaybackActive {
                hasTransferredPlaybackToCurrentDevice = true
            }
            setConnectionState(isPaused ? .paused(effectiveNowPlaying) : .playing(effectiveNowPlaying ?? fallbackNowPlaying()))
        case let .playerCommandFinished(command):
            if command == "togglePlay" {
                clearTogglePlayPauseAckWait()
            }
        case let .initializationError(message):
            setConnectionState(.error(PlaybackDisplayError(
                title: SpotiglassL10n.string("error.playback.couldNotStart.title"),
                message: message,
                recoveryAction: .reconnect
            )))
            playbackHostRecoveryTask?.cancel()
            playbackHostRecoveryTask = nil
            playbackHostRecoverySerial &+= 1
            let recoverySerial = playbackHostRecoverySerial
            let generation = playbackHostGeneration
            playbackHostRecoveryTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    if self.ownsPlaybackHostGeneration(generation),
                       self.playbackHostRecoverySerial == recoverySerial {
                        self.playbackHostRecoveryTask = nil
                    }
                }
                await self.attemptPlaybackHostRecovery(cause: .initializationError, generation: generation)
            }
        case let .authenticationError(message):
            setConnectionState(.error(PlaybackDisplayError(
                title: SpotiglassL10n.string("error.playback.signInAgain.title"),
                message: message,
                recoveryAction: .reauthenticate
            )))
        case let .accountError(message):
            setConnectionState(.error(PlaybackDisplayError(
                title: SpotiglassL10n.string("error.playback.premium.title"),
                message: message,
                recoveryAction: nil
            )))
        case let .playbackError(message):
            clearTogglePlayPauseAckWait()
            setConnectionState(.error(PlaybackDisplayError(
                title: SpotiglassL10n.string("error.playback.error.title"),
                message: message,
                recoveryAction: .retryTransfer
            )))
        case .log:
            break
        }
    }

    private func syncPlaybackVolumeToWebPlayer(
        _ volume: Double,
        mutationVersion: UInt64,
        sendSerial: UInt64,
        generation: PlaybackHostGeneration
    ) async {
        guard ownsPlaybackHostGeneration(generation), !Task.isCancelled else { return }
        guard mutationVersion == volumeMutationVersion,
              sendSerial == playbackVolumeSendSerial else { return }
        try? await webCommander.send(
            .setVolume,
            payload: ["volume": volume],
            generation: generation
        )
    }
}
