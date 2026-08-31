import Foundation

@MainActor
extension PlaybackSessionViewModel {
    @discardableResult
    func beginPlaybackHostLifecycle() -> PlaybackHostGeneration {
        playbackHostConnectTask?.cancel()
        playbackHostConnectTask = nil
        playbackHostConnectTimeoutTask?.cancel()
        playbackHostConnectTimeoutTask = nil
        playbackHostConnectTimeoutSerial &+= 1
        playbackHostRecoveryTask?.cancel()
        playbackHostRecoveryTask = nil
        playbackHostRecoverySerial &+= 1
        playbackHostAutoResumeTask?.cancel()
        playbackHostAutoResumeTask = nil
        playbackHostAutoResumeSerial &+= 1
        shuffleSyncTask?.cancel()
        shuffleSyncTask = nil
        repeatSyncTask?.cancel()
        repeatSyncTask = nil
        cancelPlaybackVolumeSend()
        pendingVolumeMutation = nil
        deferredTransportSyncTask?.cancel()
        deferredTransportSyncTask = nil
        transportSyncSchedulerTask?.cancel()
        transportSyncSchedulerTask = nil
        transportSyncSchedulerGeneration = nil
        transportSyncInFlight = false
        transportSyncGeneration = nil
        transportSyncQueued = false
        transportSyncDeferredWhileControlCommandInFlight = false
        transportSyncDeferredGeneration = nil
        connectDevicesRefreshTask?.cancel()
        connectDevicesRefreshTask = nil
        connectDevicesRefreshGeneration = nil
        isRefreshingConnectDevices = false
        inflightTransferTask?.cancel()
        inflightTransferTask = nil
        inflightTransferGeneration = nil
        activeInflightTransferSerial = nil
        inflightTransferSerial &+= 1
        clearPendingSkipCommand()
        lastSkipDispatchInstant = nil
        clearPendingPlay()
        inFlightPlayCommandID = nil
        inFlightPlayCommandKey = nil
        lastDispatchedPlayCommandKey = nil
        lastDispatchedPlayCommandInstant = nil
        playbackHostGeneration = playbackHostGeneration.advanced()
        cancelSeekDispatch()
        clearPendingSeek()
        lastSentSeek = nil
        failedSeekOwnershipKey = nil
        seekOwnershipKey = PlaybackSeekOwnershipKey(
            hostGeneration: playbackHostGeneration,
            trackURI: nil,
            trackGeneration: seekOwnershipKey.trackGeneration &+ 1
        )
        return playbackHostGeneration
    }

    @discardableResult
    func invalidatePlaybackHostLifecycle() -> PlaybackHostGeneration {
        beginPlaybackHostLifecycle()
    }

    func ownsPlaybackHostGeneration(_ generation: PlaybackHostGeneration) -> Bool {
        playbackHostGeneration == generation
    }

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
        let generation = beginPlaybackHostLifecycle()
        playbackHostReloadAttemptCount += 1
        bumpCounter(&playbackHostReloadAttemptsByCause, key: recoveryCause.rawValue)
        hasTransferredPlaybackToCurrentDevice = false
        setTransportStateKnown(false)
        autoResumeOnNextReady = true
        transferAttemptInstants.removeAll()
        transferRetryCooldownUntil = nil
        if let deviceID {
            supersededSDKDeviceIDs.insert(deviceID)
        }
        reclaimableSDKDeviceID = nil
        setActivePlaybackDeviceID(nil)
        setConnectionState(.connecting)
        deviceID = nil
        SpotiglassLog.info(
            .playback,
            "Starting Spotify playback SDK connect generation=\(generation.rawValue) timeout=\(Self.durationSeconds(playbackHostConnectTimeout))s"
        )
        webCommander.loadHost(generation: generation)
        playbackHostConnectTask = Task { [weak self] in
            guard let self, self.ownsPlaybackHostGeneration(generation), !Task.isCancelled else { return }
            defer {
                if self.ownsPlaybackHostGeneration(generation) {
                    self.playbackHostConnectTask = nil
                }
            }
            do {
                try await self.webCommander.send(.connect, payload: [:], generation: generation)
                guard self.ownsPlaybackHostGeneration(generation), !Task.isCancelled else { return }
                SpotiglassLog.info(
                    .playback,
                    "Spotify playback SDK connect command sent generation=\(generation.rawValue)"
                )
            } catch {
                guard self.ownsPlaybackHostGeneration(generation), !Task.isCancelled else { return }
                SpotiglassLog.error(
                    .playback,
                    "Spotify playback SDK connect command failed generation=\(generation.rawValue) error=\(error.localizedDescription)"
                )
                self.cancelPlaybackHostConnectTimeout()
                self.setConnectionState(.error(Self.playbackHostConnectionFailedError(for: error)))
            }
        }
        schedulePlaybackHostConnectTimeout(generation: generation)
    }

    func cancelPlaybackHostConnectTimeout() {
        playbackHostConnectTimeoutTask?.cancel()
        playbackHostConnectTimeoutTask = nil
        playbackHostConnectTimeoutSerial &+= 1
    }

    private func schedulePlaybackHostConnectTimeout(generation: PlaybackHostGeneration) {
        cancelPlaybackHostConnectTimeout()
        let serial = playbackHostConnectTimeoutSerial
        let deadline = clock.now.advanced(by: playbackHostConnectTimeout)
        playbackHostConnectTimeoutTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.clock.sleep(until: deadline, tolerance: nil)
            } catch {
                return
            }
            guard self.ownsPlaybackHostGeneration(generation),
                  self.playbackHostConnectTimeoutSerial == serial,
                  !Task.isCancelled,
                  self.connectionState == .connecting
            else { return }

            SpotiglassLog.error(
                .playback,
                "Spotify playback SDK connect timed out generation=\(generation.rawValue) after \(Self.durationSeconds(self.playbackHostConnectTimeout))s"
            )
            self.playbackHostConnectTimeoutTask = nil
            self.playbackHostConnectTask?.cancel()
            self.playbackHostConnectTask = nil
            self.setConnectionState(.error(Self.playbackHostConnectionTimedOutError()))
        }
    }

    func disconnect() async {
        let hostGeneration = playbackHostGeneration
        let generation = invalidatePlaybackHostLifecycle()
        autoResumeOnNextReady = false
        setConnectionState(.disconnected)
        deviceID = nil
        supersededSDKDeviceIDs.removeAll()
        reclaimableSDKDeviceID = nil
        setActivePlaybackDeviceID(nil)
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
        setTransportStateKnown(false)
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
        transportSyncDeferredGeneration = nil
        deferredTransportSyncTask?.cancel()
        deferredTransportSyncTask = nil
        transportSyncSchedulerTask?.cancel()
        transportSyncSchedulerTask = nil
        clearPendingSkipCommand()
        clearPendingSeek()
        cancelSeekDispatch()
        lastSeekSentInstant = nil
        lastSentSeek = nil
        failedSeekOwnershipKey = nil
        transportTransientErrorCount = 0
        transportRateLimitedUntil = nil
        localMutationSettleTicksRemaining = 0
        transferAttemptInstants.removeAll()
        transferRetryCooldownUntil = nil
        playbackHostHardReloadInstants.removeAll()
        inflightTransferTask = nil
        activeInflightTransferSerial = nil
        clearTogglePlayPauseAckWait()
        guard ownsPlaybackHostGeneration(generation) else { return }
        do {
            try await webCommander.send(.disconnect, payload: [:], generation: hostGeneration)
        } catch {
            // Disconnect best-effort; errors are non-fatal.
        }
    }

    /// Retries Spotify “transfer playback” to this device after API or transport failures that set `recoveryAction` to `.retryTransfer`.
    /// If no device ID is known, falls back to `start()` (full Web Playback SDK reconnect).
    func retryPlaybackTransfer() async {
        let generation = playbackHostGeneration
        guard ownsPlaybackHostGeneration(generation), !Task.isCancelled else { return }
        guard let deviceID else {
            guard registerHardReloadAttempt(cause: .missingDeviceRetryTransfer, enforceBudget: true) else {
                return
            }
            playbackHostReloadAttemptCount += 1
            bumpCounter(&playbackHostReloadAttemptsByCause, key: PlaybackHostRecoveryCause.missingDeviceRetryTransfer.rawValue)
            hasTransferredPlaybackToCurrentDevice = false
            setTransportStateKnown(false)
            autoResumeOnNextReady = true
            transferAttemptInstants.removeAll()
            transferRetryCooldownUntil = nil
            reclaimableSDKDeviceID = nil
            setActivePlaybackDeviceID(nil)
            setConnectionState(.connecting)
            self.deviceID = nil
            let generation = beginPlaybackHostLifecycle()
            webCommander.loadHost(generation: generation)
            playbackHostConnectTask = Task { [weak self] in
                guard let self, self.ownsPlaybackHostGeneration(generation), !Task.isCancelled else { return }
                defer {
                    if self.ownsPlaybackHostGeneration(generation) {
                        self.playbackHostConnectTask = nil
                    }
                }
                try? await self.webCommander.send(.connect, payload: [:], generation: generation)
            }
            return
        }
        hasTransferredPlaybackToCurrentDevice = false
        setTransportStateKnown(false)
        do {
            setConnectionState(.transferring(deviceID: deviceID))
            try await performTransfer(deviceID: deviceID, play: false, origin: .userRetry)
            guard ownsPlaybackHostGeneration(generation), !Task.isCancelled else { return }
            setActivePlaybackDeviceID(deviceID)
            hasTransferredPlaybackToCurrentDevice = true
            setConnectionState(.ready(deviceID: deviceID))
            noteLocalPlaybackMutation()
        } catch {
            guard ownsPlaybackHostGeneration(generation), !Task.isCancelled else { return }
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

    private func waitForPlaybackReadyAfterRecovery(
        timeout: Duration = .seconds(1),
        generation: PlaybackHostGeneration
    ) async -> Bool {
        let deadline = clock.now.advanced(by: timeout)
        let pollInterval = min(timeout, .milliseconds(25))
        while clock.now < deadline {
            guard ownsPlaybackHostGeneration(generation), !Task.isCancelled else { return false }
            if isPlaybackReadyStateForRecovery() {
                return true
            }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return false
            }
        }
        return ownsPlaybackHostGeneration(generation) && isPlaybackReadyStateForRecovery()
    }

    func attemptPlaybackHostRecovery(
        cause: PlaybackHostRecoveryCause,
        generation: PlaybackHostGeneration? = nil
    ) async {
        let generation = generation ?? playbackHostGeneration
        guard ownsPlaybackHostGeneration(generation), !isPlaybackReadyStateForRecovery() else { return }

        playbackHostReuseConnectAttemptCount += 1
        bumpCounter(&playbackHostReuseAttemptsByCause, key: cause.rawValue)
        try? await webCommander.send(.connect, payload: [:], generation: generation)
        guard ownsPlaybackHostGeneration(generation), !Task.isCancelled else { return }
        if await waitForPlaybackReadyAfterRecovery(
            timeout: playbackHostRecoveryConnectTimeout,
            generation: generation
        ) {
            guard ownsPlaybackHostGeneration(generation) else { return }
            playbackHostReuseSuccessCount += 1
            return
        }

        guard ownsPlaybackHostGeneration(generation), !Task.isCancelled else { return }
        playbackHostReuseSoftResetAttemptCount += 1
        bumpCounter(&playbackHostReuseAttemptsByCause, key: cause.rawValue)
        try? await webCommander.send(.disconnect, payload: [:], generation: generation)
        guard ownsPlaybackHostGeneration(generation), !Task.isCancelled else { return }
        do {
            try await Task.sleep(for: min(playbackHostRecoverySoftResetTimeout, .milliseconds(200)))
        } catch {
            return
        }
        guard ownsPlaybackHostGeneration(generation), !Task.isCancelled else { return }
        try? await webCommander.send(.connect, payload: [:], generation: generation)
        guard ownsPlaybackHostGeneration(generation), !Task.isCancelled else { return }
        if await waitForPlaybackReadyAfterRecovery(
            timeout: playbackHostRecoverySoftResetTimeout,
            generation: generation
        ) {
            guard ownsPlaybackHostGeneration(generation) else { return }
            playbackHostReuseSuccessCount += 1
            return
        }

        guard ownsPlaybackHostGeneration(generation), !Task.isCancelled else { return }
        let previousState = connectionState
        let reloadGeneration = generation.advanced()
        start(recoveryCause: cause)
        guard ownsPlaybackHostGeneration(reloadGeneration) else { return }
        if previousState == connectionState {
            playbackHostRecoveryFailureCount += 1
            bumpCounter(&playbackHostRecoveryFailuresByCause, key: cause.rawValue)
        }
    }
}
