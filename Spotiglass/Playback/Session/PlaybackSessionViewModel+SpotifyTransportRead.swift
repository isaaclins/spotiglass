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
                let snapshot = try await playbackAPI.fetchPlayerSnapshot()
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
                }
                transportTransientErrorCount = 0
                transportRateLimitedUntil = nil
                if localMutationSettleTicksRemaining > 0 {
                    localMutationSettleTicksRemaining -= 1
                }
                refreshTrayOutputSymbol()
            } catch {
                guard ownsPlaybackHostGeneration(generation), !Task.isCancelled else { return }
                if Self.isBenignTransportSyncCancellation(error) {
                    break
                }
                applyTransportPollingBackoff(for: error)
                // Polling should not surface transport read failures as playback errors.
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

    /// Publishes the Web API player item only while Spotify is playing on a
    /// Connect device other than the embedded Web Playback SDK device. Local
    /// SDK state remains authoritative for the Spotiglass device.
    private func applyRemotePlaybackSnapshot(_ snapshot: SpotifyPlayerSnapshot) {
        guard let localDeviceID = deviceID,
              let activeDevice = snapshot.activeDevice,
              activeDevice.deviceID != localDeviceID else { return }
        // A just-issued local command can be followed by one stale player
        // snapshot. Preserve the selected target during that settle window,
        // but accept the snapshot once it agrees with that target.
        guard localMutationSettleTicksRemaining == 0
            || activePlaybackDeviceID == activeDevice.deviceID else { return }

        setActivePlaybackDeviceID(activeDevice.deviceID)
        let remoteNowPlaying = snapshot.playbackNowPlaying
        let suppressed = shouldSuppressStaleStateChange(nowPlaying: remoteNowPlaying)
        SpotiglassLog.info(
            .playback,
            "Remote player snapshot deviceID=\(activeDevice.deviceID) itemURI=\(remoteNowPlaying?.uri ?? "<nil>") isPlaying=\(snapshot.isPlaying) progressMs=\(snapshot.progressMilliseconds ?? 0) suppressed=\(suppressed)"
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

    private func expirePendingVolumeMutationIfNeeded(
        startedWithVolumeMutationVersion requestVersion: UInt64
    ) {
        guard requestVersion == volumeMutationVersion,
              let pendingVolumeMutation,
              clock.now >= pendingVolumeMutation.deadline else { return }
        self.pendingVolumeMutation = nil
    }

    private func applyTransportVolume(
        _ snapshot: SpotifyPlayerSnapshot,
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
            try await playbackAPI.fetchAvailableDevices()
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

    func noteLocalPlaybackMutation(shouldSyncTransportImmediately: Bool = true) {
        localMutationSettleTicksRemaining = max(localMutationSettleTicksRemaining, 2)
        transportRateLimitedUntil = nil
        guard shouldSyncTransportImmediately else { return }
        scheduleTransportSync()
    }
}
