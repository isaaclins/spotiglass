import Foundation

@MainActor
extension PlaybackSessionViewModel {
    /// Refreshes shuffle/repeat from Spotify (`GET /v1/me/player`). Safe to call from UI and poll paths.
    /// Concurrent calls are coalesced so only one in-flight request runs at a time.
    func syncTransportFromSpotify(
        minimumShuffleMutationVersion: UInt64? = nil,
        generation: PlaybackHostGeneration? = nil
    ) async {
        let generation = generation ?? playbackHostGeneration
        guard ownsPlaybackHostGeneration(generation), !Task.isCancelled else { return }
        if let scheduledTask = transportSyncSchedulerTask,
           transportSyncSchedulerGeneration == generation {
            await scheduledTask.value
            return
        }
        await performTransportSync(
            minimumShuffleMutationVersion: minimumShuffleMutationVersion,
            generation: generation
        )
    }

    private func performTransportSync(
        minimumShuffleMutationVersion: UInt64?,
        generation: PlaybackHostGeneration
    ) async {
        guard ownsPlaybackHostGeneration(generation), !Task.isCancelled else { return }
        guard controlCommandsInFlight == 0 else {
            transportSyncDeferredWhileControlCommandInFlight = true
            transportSyncDeferredGeneration = generation
            return
        }
        if transportSyncInFlight {
            if transportSyncGeneration == generation {
                transportSyncQueued = true
            }
            return
        }

        repeat {
            guard ownsPlaybackHostGeneration(generation), !Task.isCancelled else { return }
            transportSyncQueued = false
            transportSyncInFlight = true
            transportSyncGeneration = generation
            defer {
                if transportSyncGeneration == generation {
                    transportSyncInFlight = false
                    transportSyncGeneration = nil
                }
            }

            do {
                let volumeMutationVersionAtRequest = volumeMutationVersion
                let snapshot = try await provider.fetchPlaybackState()
                guard ownsPlaybackHostGeneration(generation), !Task.isCancelled else { return }
                if let snapshot {
                    latestPlayerSnapshot = snapshot
                    setTransportStateKnown(true)
                    if localMutationSettleTicksRemaining == 0,
                       let activeDeviceID = snapshot.activeDevice?.deviceID {
                        setActivePlaybackDeviceID(activeDeviceID)
                    }
                    applyTransportVolume(
                        snapshot,
                        startedWithVolumeMutationVersion: volumeMutationVersionAtRequest
                    )
                    applyTransportShuffleEnabled(
                        snapshot.transport.shuffle,
                        minimumMutationVersion: minimumShuffleMutationVersion
                    )
                    applyTransportRepeatMode(snapshot.transport.repeatMode)
                    applyRemotePlaybackSnapshot(snapshot)
                } else {
                    latestPlayerSnapshot = nil
                    setTransportStateKnown(false)
                    expirePendingVolumeMutationIfNeeded(
                        startedWithVolumeMutationVersion: volumeMutationVersionAtRequest
                    )
                    applyEmptyReadForReadOnlyPlayer()
                }
                transportTransientErrorCount = 0
                transportRateLimitedUntil = nil
                if localMutationSettleTicksRemaining > 0 {
                    localMutationSettleTicksRemaining -= 1
                    if localMutationSettleTicksRemaining == 0 {
                        localCommandExpectsPlaying = nil
                    }
                }
                refreshTrayOutputSymbol()
            } catch {
                guard ownsPlaybackHostGeneration(generation), !Task.isCancelled else { return }
                if Self.isBenignTransportSyncCancellation(error) {
                    break
                }
                if Self.isMissingPlaybackScope(error) {
                    // A stale OAuth grant is actionable: stop polling the same
                    // denied request and put the existing Account ▸ Reconnect
                    // path in front of the user instead of leaving an empty
                    // transport behind.
                    setConnectionState(.error(Self.displayError(for: error)))
                    transportTransientErrorCount = 0
                    transportRateLimitedUntil = nil
                    break
                }
                applyTransportPollingBackoff(for: error)
                // Transient polling failures should not surface as playback errors.
            }
        } while transportSyncQueued && ownsPlaybackHostGeneration(generation) && !Task.isCancelled

        guard ownsPlaybackHostGeneration(generation), !Task.isCancelled else { return }
        if transportSyncQueued {
            scheduleTransportSync(
                minimumShuffleMutationVersion: minimumShuffleMutationVersion,
                generation: generation
            )
        }
    }

    /// Publishes the read player item while the playing player's state is only
    /// read: Spotify on a Connect device other than the embedded Web Playback
    /// SDK device, or an in-app player that does not push state events. Pushed
    /// SDK state remains authoritative for the Spotiglass device.
    private func applyRemotePlaybackSnapshot(_ snapshot: MusicPlaybackSnapshot) {
        guard let localDeviceID = deviceID else { return }
        let snapshotDeviceID: String
        if provider.capabilities.contains(.pushesPlayerState) {
            guard let activeDevice = snapshot.activeDevice,
                  activeDevice.deviceID != localDeviceID else { return }
            // A just-issued local command can be followed by one stale player
            // snapshot. Preserve the selected target during that settle window,
            // but accept the snapshot once it agrees with that target.
            guard localMutationSettleTicksRemaining == 0
                || activePlaybackDeviceID == activeDevice.deviceID else { return }
            snapshotDeviceID = activeDevice.deviceID
        } else {
            // The in-app player's own reads lag its commands (a player can
            // still report "playing" right after it was stopped), so during
            // the settle window after a local command only a read that agrees
            // with that command is applied.
            guard localMutationSettleTicksRemaining == 0
                || readAgreesWithLocalCommand(snapshot) else { return }
            snapshotDeviceID = snapshot.activeDevice?.deviceID ?? localDeviceID
        }

        setActivePlaybackDeviceID(snapshotDeviceID)
        let remoteNowPlaying = snapshot.playbackNowPlaying
        let suppressed = shouldSuppressStaleStateChange(nowPlaying: remoteNowPlaying)
        SpotiglassLog.info(
            .playback,
            "Remote player snapshot deviceID=\(snapshotDeviceID) itemURI=\(remoteNowPlaying?.uri ?? "<nil>") isPlaying=\(snapshot.isPlaying) progressMs=\(snapshot.progressMilliseconds ?? 0) suppressed=\(suppressed)"
        )
        observeSkipAdvance(nowPlayingURI: remoteNowPlaying?.uri)
        guard !suppressed else { return }

        let authoritativeState: PlaybackConnectionState = snapshot.isPlaying
            ? .playing(remoteNowPlaying ?? fallbackNowPlaying())
            : .paused(remoteNowPlaying)
        updateSeekOwnership(from: authoritativeState)
        if failedSeekOwnershipKey == seekOwnershipKey {
            return
        }
        let effectiveNowPlaying = applyPendingSeekSuppression(to: remoteNowPlaying)
        if snapshot.isPlaying {
            setConnectionState(.playing(effectiveNowPlaying ?? fallbackNowPlaying()))
        } else {
            setConnectionState(.paused(effectiveNowPlaying))
        }
    }

    /// For a player whose state is only read: whether a read taken during the
    /// settle window confirms the last local command instead of predating it.
    /// Only play / pause can be stale this way (a player still reports
    /// "playing" right after it was stopped); which item plays is fenced by the
    /// pending play and skip tracking.
    private func readAgreesWithLocalCommand(_ snapshot: MusicPlaybackSnapshot) -> Bool {
        guard let localCommandExpectsPlaying else { return true }
        return snapshot.isPlaying == localCommandExpectsPlaying
    }

    /// For a player whose state is only read, an empty read means nothing is
    /// playing on it any more. Nothing else will correct a `.playing` or
    /// `.paused` item, so fall back to `.ready`, unless a play command is still
    /// waiting for the player to start.
    private func applyEmptyReadForReadOnlyPlayer() {
        guard !provider.capabilities.contains(.pushesPlayerState),
              pendingPlayTransition == nil,
              let localDeviceID = deviceID else { return }
        switch connectionState {
        case .playing, .paused:
            SpotiglassLog.info(.playback, "Empty player read; nothing is playing on deviceID=\(localDeviceID)")
            setConnectionState(.ready(deviceID: localDeviceID))
        case .disconnected, .connecting, .ready, .transferring, .unavailable, .error:
            break
        }
    }

    private func expirePendingVolumeMutationIfNeeded(
        startedWithVolumeMutationVersion requestVersion: UInt64
    ) {
        guard requestVersion == volumeMutationVersion,
              let pendingVolumeMutation,
              clock.now >= pendingVolumeMutation.deadline else { return }
        self.pendingVolumeMutation = nil
    }

    private func applyTransportVolume(
        _ snapshot: MusicPlaybackSnapshot,
        startedWithVolumeMutationVersion requestVersion: UInt64
    ) {
        guard requestVersion == volumeMutationVersion else { return }
        expirePendingVolumeMutationIfNeeded(
            startedWithVolumeMutationVersion: requestVersion
        )
        guard let localDeviceID = deviceID,
              let activeDevice = snapshot.activeDevice,
              activeDevice.deviceID == localDeviceID,
              activeDevice.isActive,
              let volume = activeDevice.volumeFraction else { return }

        if let pending = pendingVolumeMutation {
            if abs(volume - pending.target) <= volumeMatchTolerance {
                cancelPlaybackVolumeSend()
                applyRemotePlaybackVolume(volume)
                pendingVolumeMutation = nil
                return
            }
            guard clock.now >= pending.deadline else { return }
            cancelPlaybackVolumeSend()
            applyRemotePlaybackVolume(volume)
            pendingVolumeMutation = nil
            return
        }

        cancelPlaybackVolumeSend()
        applyRemotePlaybackVolume(volume)
    }

    /// Schedules a single coalesced `syncTransportFromSpotify()` on the main actor.
    @discardableResult
    func scheduleTransportSync(
        minimumShuffleMutationVersion: UInt64? = nil,
        generation: PlaybackHostGeneration? = nil
    ) -> Task<Void, Never>? {
        let generation = generation ?? playbackHostGeneration
        guard ownsPlaybackHostGeneration(generation), !Task.isCancelled else { return nil }
        if let transportSyncSchedulerTask {
            if transportSyncSchedulerGeneration == generation {
                return transportSyncSchedulerTask
            }
            transportSyncSchedulerTask.cancel()
            self.transportSyncSchedulerTask = nil
            transportSyncSchedulerGeneration = nil
        }
        if transportSyncInFlight {
            if transportSyncGeneration == generation {
                transportSyncQueued = true
            }
            return nil
        }
        let task = Task { @MainActor [weak self] in
            defer {
                if self?.transportSyncSchedulerGeneration == generation {
                    self?.transportSyncSchedulerTask = nil
                    self?.transportSyncSchedulerGeneration = nil
                }
            }
            await self?.performTransportSync(
                minimumShuffleMutationVersion: minimumShuffleMutationVersion,
                generation: generation
            )
        }
        transportSyncSchedulerTask = task
        transportSyncSchedulerGeneration = generation
        return task
    }

    private static func isMissingPlaybackScope(_ error: Error) -> Bool {
        guard let apiError = error as? SpotifyAPIError else { return false }
        if case .insufficientScope = apiError {
            return true
        }
        return false
    }

    private static func isBenignTransportSyncCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    private func applyTransportPollingBackoff(for error: Error) {
        guard let apiError = error as? SpotifyAPIError else {
            transportTransientErrorCount = 0
            return
        }
        switch apiError {
        case let .rateLimited(retryAfter):
            let retryDelay = max(1, retryAfter ?? 15)
            transportRateLimitedUntil = clock.now.advanced(by: .seconds(retryDelay))
            transportTransientErrorCount = 0
        case let .server(statusCode, _, _) where statusCode >= 500:
            transportTransientErrorCount = min(transportTransientErrorCount + 1, 4)
        case .network:
            transportTransientErrorCount = min(transportTransientErrorCount + 1, 4)
        default:
            transportTransientErrorCount = 0
        }
    }

    func refreshConnectDevices(
        force: Bool = false,
        generation: PlaybackHostGeneration? = nil
    ) async {
        let generation = generation ?? playbackHostGeneration
        guard ownsPlaybackHostGeneration(generation), !Task.isCancelled else { return }
        // Services without device transfer have no device list to show.
        guard let deviceTransfer = provider.deviceTransfer else { return }
        if !force,
           let lastConnectDevicesRefreshAt,
           clock.now < lastConnectDevicesRefreshAt.advanced(by: connectDevicesFreshnessWindow) {
            return
        }

        if let inFlight = connectDevicesRefreshTask,
           connectDevicesRefreshGeneration == generation {
            isRefreshingConnectDevices = true
            do {
                let devices = try await inFlight.value
                guard ownsPlaybackHostGeneration(generation), !Task.isCancelled else { return }
                connectDevices = devices
                lastConnectDevicesRefreshAt = clock.now
                refreshTrayOutputSymbol()
            } catch {
                guard ownsPlaybackHostGeneration(generation), !Task.isCancelled else { return }
                connectDevices = []
            }
            return
        }

        if connectDevicesRefreshTask != nil {
            connectDevicesRefreshTask?.cancel()
            connectDevicesRefreshTask = nil
            connectDevicesRefreshGeneration = nil
        }

        let refreshTask = Task {
            try await deviceTransfer.fetchAvailableDevices()
        }
        connectDevicesRefreshTask = refreshTask
        connectDevicesRefreshGeneration = generation
        isRefreshingConnectDevices = true
        defer {
            if connectDevicesRefreshGeneration == generation {
                isRefreshingConnectDevices = false
                connectDevicesRefreshTask = nil
                connectDevicesRefreshGeneration = nil
            }
        }
        do {
            let devices = try await refreshTask.value
            guard ownsPlaybackHostGeneration(generation), !Task.isCancelled else { return }
            connectDevices = devices
            lastConnectDevicesRefreshAt = clock.now
            refreshTrayOutputSymbol()
        } catch {
            guard ownsPlaybackHostGeneration(generation), !Task.isCancelled else { return }
            connectDevices = []
        }
    }

    func noteLocalPlaybackMutation(
        shouldSyncTransportImmediately: Bool = true,
        playExpectation: LocalCommandPlayExpectation = .unchanged
    ) {
        localMutationSettleTicksRemaining = max(localMutationSettleTicksRemaining, 2)
        transportRateLimitedUntil = nil
        switch playExpectation {
        case .unchanged: break
        case .playing: localCommandExpectsPlaying = true
        case .paused: localCommandExpectsPlaying = false
        case .none: localCommandExpectsPlaying = nil
        }
        if !provider.capabilities.contains(.pushesPlayerState) {
            // Reads are this player's only state source. Restart the poll loop
            // so it reads at the settle cadence now instead of finishing a long
            // sleep picked before the command (20 s while `.ready`).
            restartTransportPollingIfNeeded()
        }
        guard shouldSyncTransportImmediately else { return }
        scheduleTransportSync()
    }
}
