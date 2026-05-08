import Foundation

@MainActor
extension PlaybackSessionViewModel {
    func start(recoveryCause: PlaybackHostRecoveryCause = .manualReconnect) {
        switch connectionState {
        case .disconnected, .error, .unavailable:
            break
        case .connecting, .ready, .transferring, .playing, .paused:
            return
        }
        let enforceHardReloadBudget = recoveryCause != .manualReconnect
        guard registerHardReloadAttempt(cause: recoveryCause, enforceBudget: enforceHardReloadBudget) else {
            return
        }
        playbackHostReloadAttemptCount += 1
        bumpCounter(&playbackHostReloadAttemptsByCause, key: recoveryCause.rawValue)
        hasTransferredPlaybackToCurrentDevice = false
        autoResumeOnNextReady = true
        transferAttemptInstants.removeAll()
        transferRetryCooldownUntil = nil
        setConnectionState(.connecting)
        deviceID = nil
        webCommander.loadHost()
        Task {
            try? await webCommander.send(.connect, payload: [:])
        }
    }

    func disconnect() async {
        do {
            try await webCommander.send(.disconnect, payload: [:])
        } catch {
            // Disconnect best-effort; errors are non-fatal.
        }
        deviceID = nil
        hasTransferredPlaybackToCurrentDevice = false
        activePlaylistID = nil
        sdkNextTracks = []
        shuffleEnabled = false
        lastConfirmedShuffleEnabled = nil
        inFlightShuffleTarget = nil
        queuedShuffleTarget = nil
        shuffleMutationVersion = 0
        repeatMode = .off
        confirmedRepeatMode = .off
        latestPlayerSnapshot = nil
        connectDevices = []
        lastConnectDevicesRefreshAt = nil
        connectDevicesRefreshTask?.cancel()
        connectDevicesRefreshTask = nil
        trayOutputSymbolName = "headphones"
        clearPendingShuffle()
        clearPendingRepeat()
        repeatWriteInFlight = false
        desiredRepeatMode = nil
        lastRepeatWriteAt = nil
        lastRepeatCommandedMode = nil
        clearPendingPlay()
        inFlightPlayCommandID = nil
        inFlightPlayCommandKey = nil
        transportSyncDeferredWhileControlCommandInFlight = false
        deferredTransportSyncTask?.cancel()
        deferredTransportSyncTask = nil
        clearPendingSkipCommand()
        clearPendingSeek()
        seekDispatchTask?.cancel()
        seekDispatchTask = nil
        lastSeekSentInstant = nil
        lastSentSeekPositionMilliseconds = nil
        transportTransientErrorCount = 0
        transportRateLimitedUntil = nil
        localMutationSettleTicksRemaining = 0
        transferAttemptInstants.removeAll()
        transferRetryCooldownUntil = nil
        playbackHostHardReloadInstants.removeAll()
        inflightTransferTask = nil
        activeInflightTransferSerial = nil
        clearTogglePlayPauseAckWait()
        setConnectionState(.disconnected)
    }

    /// Retries Spotify “transfer playback” to this device after API or transport failures that set `recoveryAction` to `.retryTransfer`.
    /// If no device ID is known, falls back to `start()` (full Web Playback SDK reconnect).
    func retryPlaybackTransfer() async {
        guard let deviceID else {
            guard registerHardReloadAttempt(cause: .missingDeviceRetryTransfer, enforceBudget: true) else {
                return
            }
            playbackHostReloadAttemptCount += 1
            bumpCounter(&playbackHostReloadAttemptsByCause, key: PlaybackHostRecoveryCause.missingDeviceRetryTransfer.rawValue)
            hasTransferredPlaybackToCurrentDevice = false
            autoResumeOnNextReady = true
            transferAttemptInstants.removeAll()
            transferRetryCooldownUntil = nil
            setConnectionState(.connecting)
            self.deviceID = nil
            webCommander.loadHost()
            Task {
                try? await webCommander.send(.connect, payload: [:])
            }
            return
        }
        hasTransferredPlaybackToCurrentDevice = false
        do {
            setConnectionState(.transferring(deviceID: deviceID))
            try await performTransfer(deviceID: deviceID, play: false, origin: .userRetry)
            hasTransferredPlaybackToCurrentDevice = true
            setConnectionState(.ready(deviceID: deviceID))
            noteLocalPlaybackMutation()
        } catch {
            setConnectionState(.error(Self.displayError(for: error)))
        }
    }

    func registerHardReloadAttempt(cause: PlaybackHostRecoveryCause, enforceBudget: Bool = true) -> Bool {
        if !enforceBudget {
            return true
        }
        let now = clock.now
        prunePlaybackHostHardReloadWindow(now: now)
        if let last = playbackHostHardReloadInstants.last,
           now < last.advanced(by: playbackHostHardReloadCooldown) {
            playbackHostReloadSuppressedCooldownCount += 1
            bumpCounter(&playbackHostReloadSuppressedCooldownByCause, key: cause.rawValue)
            return false
        }
        if playbackHostHardReloadInstants.count >= playbackHostHardReloadWindowMax {
            playbackHostReloadSuppressedBudgetCount += 1
            bumpCounter(&playbackHostReloadSuppressedBudgetByCause, key: cause.rawValue)
            return false
        }
        playbackHostHardReloadInstants.append(now)
        return true
    }

    func bumpCounter(_ counter: inout [String: Int], key: String) {
        counter[key, default: 0] += 1
    }

    private func prunePlaybackHostHardReloadWindow(now: ContinuousClock.Instant) {
        let cutoff = now.advanced(by: .zero - playbackHostHardReloadWindow)
        playbackHostHardReloadInstants.removeAll { $0 < cutoff }
    }

    private func isPlaybackReadyStateForRecovery() -> Bool {
        switch connectionState {
        case .ready, .playing, .paused, .transferring:
            return true
        case .disconnected, .connecting, .unavailable, .error:
            return false
        }
    }

    private func waitForPlaybackReadyAfterRecovery(timeout: Duration = .seconds(1)) async -> Bool {
        let deadline = clock.now.advanced(by: timeout)
        let pollInterval = min(timeout, .milliseconds(25))
        while clock.now < deadline {
            if isPlaybackReadyStateForRecovery() {
                return true
            }
            try? await Task.sleep(for: pollInterval)
        }
        return isPlaybackReadyStateForRecovery()
    }

    func attemptPlaybackHostRecovery(cause: PlaybackHostRecoveryCause) async {
        guard !isPlaybackReadyStateForRecovery() else { return }

        playbackHostReuseConnectAttemptCount += 1
        bumpCounter(&playbackHostReuseAttemptsByCause, key: cause.rawValue)
        try? await webCommander.send(.connect, payload: [:])
        if await waitForPlaybackReadyAfterRecovery(timeout: playbackHostRecoveryConnectTimeout) {
            playbackHostReuseSuccessCount += 1
            return
        }

        playbackHostReuseSoftResetAttemptCount += 1
        bumpCounter(&playbackHostReuseAttemptsByCause, key: cause.rawValue)
        try? await webCommander.send(.disconnect, payload: [:])
        try? await Task.sleep(for: min(playbackHostRecoverySoftResetTimeout, .milliseconds(200)))
        try? await webCommander.send(.connect, payload: [:])
        if await waitForPlaybackReadyAfterRecovery(timeout: playbackHostRecoverySoftResetTimeout) {
            playbackHostReuseSuccessCount += 1
            return
        }

        let previousState = connectionState
        start(recoveryCause: cause)
        if previousState == connectionState {
            playbackHostRecoveryFailureCount += 1
            bumpCounter(&playbackHostRecoveryFailuresByCause, key: cause.rawValue)
        }
    }
}
