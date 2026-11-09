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
                let pressSerialAtRequest = playPauseRequestSerial
                let snapshot = try await provider.fetchPlaybackState()
                guard ownsPlaybackHostGeneration(generation), !Task.isCancelled else { return }
                // Checked before the read is applied: applying it can end the expectation.
                let readHoldsSettle = snapshot.map {
                    playPauseReadHoldsSettle($0, predatesPress: playPauseRequestSerial != pressSerialAtRequest)
                } ?? false
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
                // A read still showing the state from before a pause or resume doesn't end the
                // window; it stays open on its last tick until a read agrees or the hold ends.
                if localMutationSettleTicksRemaining > 1
                    || (localMutationSettleTicksRemaining == 1 && !readHoldsSettle) {
                    localMutationSettleTicksRemaining -= 1
                    // A play still waiting to start keeps its expectation past
                    // the settle window; `clearPendingPlay()` ends it then.
                    if localMutationSettleTicksRemaining == 0, pendingPlayTransition == nil {
                        localCommandExpectsPlaying = nil
                    }
                    if localMutationSettleTicksRemaining == 0 {
                        skipLeftItemURI = nil
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
            // snapshot. Preserve the selected target and the last pause or resume
            // during that settle window, but accept the snapshot once it agrees
            // with both (a late read must not flip a press back, #437).
            guard localMutationSettleTicksRemaining == 0
                || (activePlaybackDeviceID == activeDevice.deviceID
                    && readAgreesWithLocalCommand(snapshot)) else { return }
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
    /// settle window confirms the last local command instead of predating it:
    /// its play / pause must match the last pause, resume or play (a player
    /// still reports "playing" right after it was paused), and after a skip it
    /// must no longer show the item the skip left. Which item a play starts is
    /// fenced by the pending play.
    private func readAgreesWithLocalCommand(_ snapshot: MusicPlaybackSnapshot) -> Bool {
        if let skipLeftItemURI {
            let readURI = snapshot.playbackNowPlaying?.uri
            if readURI == skipLeftItemURI { return false }
            if readURI != nil { self.skipLeftItemURI = nil }
        }
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
            // Nothing is left to pause or resume, so the next toggle must not
            // follow the expectation of a command the player already finished.
            localCommandExpectsPlaying = nil
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
        MusicPlaybackError.from(error)?.reason == .missingPermission
    }

    private static func isBenignTransportSyncCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    private func applyTransportPollingBackoff(for error: Error) {
        guard let playbackError = MusicPlaybackError.from(error) else {
            transportTransientErrorCount = 0
            return
        }
        switch playbackError.reason {
        case let .rateLimited(retryAfter):
            let retryDelay = max(1, retryAfter ?? 15)
            transportRateLimitedUntil = clock.now.advanced(by: .seconds(retryDelay))
            transportTransientErrorCount = 0
        case .server, .network:
            transportTransientErrorCount = min(transportTransientErrorCount + 1, 4)
        case .signInExpired, .missingPermission, .subscriptionRequired, .notFound, .explicitContentRestricted, .failed:
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
        }
        if !provider.capabilities.contains(.pushesPlayerState),
           transportPollReadingSerial != transportPollLoopSerial {
            // Reads are this player's only state source. Restart the poll loop
            // so it reads at the settle cadence now instead of finishing a long
            // sleep picked before the command (20 s while `.ready`). A loop
            // that is mid-read picks the settle cadence itself after the read,
            // and cancelling it would drop the read queued below.
            restartTransportPollingIfNeeded()
        }
        guard shouldSyncTransportImmediately else { return }
        scheduleTransportSync()
    }
}
