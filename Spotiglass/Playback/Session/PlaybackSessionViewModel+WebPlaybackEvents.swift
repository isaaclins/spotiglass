import Foundation

@MainActor
extension PlaybackSessionViewModel {
    func handle(_ event: PlaybackBridgeEvent) {
        switch event {
        case .ready(let deviceID):
            SpotiglassLog.info(
                .playback,
                "SDK ready deviceID=\(deviceID) previousDeviceID=\(self.deviceID ?? "<nil>") autoResumeOnNextReady=\(autoResumeOnNextReady)"
            )
            if self.deviceID != deviceID {
                hasTransferredPlaybackToCurrentDevice = false
            }
            self.deviceID = deviceID
            setConnectionState(.ready(deviceID: deviceID))
            refreshTrayOutputSymbol()
            let shouldAutoResume = autoResumeOnNextReady
            autoResumeOnNextReady = false
            Task {
                await syncPlaybackVolumeToWebPlayer()
                if shouldAutoResume {
                    await autoResumeFromStaleSpotiglassDeviceIfNeeded(targetDeviceID: deviceID)
                }
            }
        case .notReady(let deviceID):
            SpotiglassLog.info(.playback, "SDK not_ready deviceID=\(deviceID)")
            if self.deviceID == deviceID {
                self.deviceID = nil
            }
            hasTransferredPlaybackToCurrentDevice = false
            clearPendingSkipCommand()
            sdkNextTracks = []
            setConnectionState(
                .unavailable("Spotify playback device is no longer available. Reconnect playback to continue."))
            Task {
                await attemptPlaybackHostRecovery(cause: .notReady)
            }
        case .stateChanged(let nowPlaying, let isPaused, let nextTracks):
            let suppressed = shouldSuppressStaleStateChange(nowPlaying: nowPlaying)
            SpotiglassLog.info(
                .playback,
                "SDK state_changed nowPlayingURI=\(nowPlaying?.uri ?? "<nil>") isPaused=\(isPaused) nextCount=\(nextTracks.count) pendingPlayURI=\(pendingPlayURI ?? "<nil>") suppressed=\(suppressed)"
            )
            observeSkipAdvance(nowPlayingURI: nowPlaying?.uri)
            if suppressed {
                return
            }
            sdkNextTracks = nextTracks
            let effectiveNowPlaying = applyPendingSeekSuppression(to: nowPlaying)
            if effectiveNowPlaying != nil {
                hasTransferredPlaybackToCurrentDevice = true
            }
            setConnectionState(
                isPaused ? .paused(effectiveNowPlaying) : .playing(effectiveNowPlaying ?? fallbackNowPlaying()))
        case .playerCommandFinished(let command):
            if command == "togglePlay" {
                clearTogglePlayPauseAckWait()
            }
        case .initializationError(let message):
            setConnectionState(
                .error(
                    PlaybackDisplayError(
                        title: SpotiglassL10n.string("error.playback.couldNotStart.title"),
                        message: message,
                        recoveryAction: .reconnect
                    )))
            Task {
                await attemptPlaybackHostRecovery(cause: .initializationError)
            }
        case .authenticationError(let message):
            setConnectionState(
                .error(
                    PlaybackDisplayError(
                        title: SpotiglassL10n.string("error.playback.signInAgain.title"),
                        message: message,
                        recoveryAction: .reauthenticate
                    )))
        case .accountError(let message):
            setConnectionState(
                .error(
                    PlaybackDisplayError(
                        title: SpotiglassL10n.string("error.playback.premium.title"),
                        message: message,
                        recoveryAction: nil
                    )))
        case .playbackError(let message):
            clearTogglePlayPauseAckWait()
            setConnectionState(
                .error(
                    PlaybackDisplayError(
                        title: SpotiglassL10n.string("error.playback.error.title"),
                        message: message,
                        recoveryAction: .retryTransfer
                    )))
        case .log:
            break
        }
    }

    private func syncPlaybackVolumeToWebPlayer() async {
        try? await webCommander.send(.setVolume, payload: ["volume": playbackVolume])
    }
}
