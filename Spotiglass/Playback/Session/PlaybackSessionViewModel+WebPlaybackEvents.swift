import Foundation

@MainActor
extension PlaybackSessionViewModel {
    func handle(_ event: PlaybackBridgeEvent) {
        switch event {
        case let .ready(deviceID):
            if self.deviceID != deviceID {
                hasTransferredPlaybackToCurrentDevice = false
            }
            self.deviceID = deviceID
            setConnectionState(.ready(deviceID: deviceID))
            // WebKit helper PIDs (WebContent, GPU, …) may spawn only after the Web
            // Playback SDK is ready. Rebuild the equalizer tap so Core Audio includes them.
            NotificationCenter.default.post(name: .spotiglassPlaybackDeviceReady, object: nil)
            refreshTrayOutputSymbol()
            let shouldAutoResume = autoResumeOnNextReady
            autoResumeOnNextReady = false
            Task {
                await syncPlaybackVolumeToWebPlayer()
                if shouldAutoResume {
                    await autoResumeFromStaleSpotiglassDeviceIfNeeded(targetDeviceID: deviceID)
                }
            }
        case let .notReady(deviceID):
            if self.deviceID == deviceID {
                self.deviceID = nil
            }
            hasTransferredPlaybackToCurrentDevice = false
            clearPendingSkipCommand()
            sdkNextTracks = []
            setConnectionState(.unavailable("Spotify playback device is no longer available. Reconnect playback to continue."))
            Task {
                await attemptPlaybackHostRecovery(cause: .notReady)
            }
        case let .stateChanged(nowPlaying, isPaused, nextTracks):
            observeSkipAdvance(nowPlayingURI: nowPlaying?.uri)
            if shouldSuppressStaleStateChange(nowPlaying: nowPlaying) {
                return
            }
            sdkNextTracks = nextTracks
            let effectiveNowPlaying = applyPendingSeekSuppression(to: nowPlaying)
            if effectiveNowPlaying != nil {
                hasTransferredPlaybackToCurrentDevice = true
            }
            setConnectionState(isPaused ? .paused(effectiveNowPlaying) : .playing(effectiveNowPlaying ?? fallbackNowPlaying()))
        case let .playerCommandFinished(command):
            if command == "togglePlay" {
                clearTogglePlayPauseAckWait()
            }
        case let .initializationError(message):
            setConnectionState(.error(PlaybackDisplayError(title: "Playback could not start", message: message, recoveryAction: .reconnect)))
            Task {
                await attemptPlaybackHostRecovery(cause: .initializationError)
            }
        case let .authenticationError(message):
            setConnectionState(.error(PlaybackDisplayError(title: "Sign in again", message: message, recoveryAction: .reauthenticate)))
        case let .accountError(message):
            setConnectionState(.error(PlaybackDisplayError(title: "Spotify Premium required", message: message, recoveryAction: nil)))
        case let .playbackError(message):
            clearTogglePlayPauseAckWait()
            setConnectionState(.error(PlaybackDisplayError(title: "Playback error", message: message, recoveryAction: .retryTransfer)))
        case let .log(message):
            latestLog = message
        }
    }

    private func syncPlaybackVolumeToWebPlayer() async {
        try? await webCommander.send(.setVolume, payload: ["volume": playbackVolume])
    }
}
