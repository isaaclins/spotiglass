import Foundation

@MainActor
extension PlaybackSessionViewModel {
    /// Refreshes shuffle/repeat from Spotify (`GET /v1/me/player`). Safe to call from UI and poll paths.
    /// Concurrent calls are coalesced so only one in-flight request runs at a time.
    func syncTransportFromSpotify(minimumShuffleMutationVersion: UInt64? = nil) async {
        if let scheduledTask = transportSyncSchedulerTask {
            await scheduledTask.value
            return
        }
        await performTransportSync(minimumShuffleMutationVersion: minimumShuffleMutationVersion)
    }

    private func performTransportSync(minimumShuffleMutationVersion: UInt64?) async {
        guard controlCommandsInFlight == 0 else {
            transportSyncDeferredWhileControlCommandInFlight = true
            return
        }
        if transportSyncInFlight {
            transportSyncQueued = true
            return
        }

        repeat {
            transportSyncQueued = false
            transportSyncInFlight = true
            defer { transportSyncInFlight = false }

            do {
                if let snapshot = try await playbackAPI.fetchPlayerSnapshot() {
                    latestPlayerSnapshot = snapshot
                    setTransportStateKnown(true)
                    if localMutationSettleTicksRemaining == 0,
                       let activeDeviceID = snapshot.activeDevice?.deviceID {
                        setActivePlaybackDeviceID(activeDeviceID)
                    }
                    applyTransportShuffleEnabled(
                        snapshot.transport.shuffle,
                        minimumMutationVersion: minimumShuffleMutationVersion
                    )
                    applyTransportRepeatMode(snapshot.transport.repeatMode)
                } else {
                    latestPlayerSnapshot = nil
                    setTransportStateKnown(false)
                }
                transportTransientErrorCount = 0
                transportRateLimitedUntil = nil
                if localMutationSettleTicksRemaining > 0 {
                    localMutationSettleTicksRemaining -= 1
                }
                refreshTrayOutputSymbol()
            } catch {
                if Self.isBenignTransportSyncCancellation(error) {
                    break
                }
                applyTransportPollingBackoff(for: error)
                // Polling should not surface transport read failures as playback errors.
            }
        } while transportSyncQueued

        if transportSyncQueued {
            scheduleTransportSync(minimumShuffleMutationVersion: minimumShuffleMutationVersion)
        }
    }

    /// Schedules a single coalesced `syncTransportFromSpotify()` on the main actor.
    @discardableResult
    func scheduleTransportSync(minimumShuffleMutationVersion: UInt64? = nil) -> Task<Void, Never>? {
        if let transportSyncSchedulerTask { return transportSyncSchedulerTask }
        if transportSyncInFlight {
            transportSyncQueued = true
            return nil
        }
        let task = Task { @MainActor [weak self] in
            defer { self?.transportSyncSchedulerTask = nil }
            await self?.performTransportSync(minimumShuffleMutationVersion: minimumShuffleMutationVersion)
        }
        transportSyncSchedulerTask = task
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

    func refreshConnectDevices(force: Bool = false) async {
        if !force,
           let lastConnectDevicesRefreshAt,
           clock.now < lastConnectDevicesRefreshAt.advanced(by: connectDevicesFreshnessWindow) {
            return
        }

        if let inFlight = connectDevicesRefreshTask {
            isRefreshingConnectDevices = true
            defer { isRefreshingConnectDevices = false }
            do {
                connectDevices = try await inFlight.value
                lastConnectDevicesRefreshAt = clock.now
                refreshTrayOutputSymbol()
            } catch {
                connectDevices = []
            }
            return
        }

        let refreshTask = Task {
            try await playbackAPI.fetchAvailableDevices()
        }
        connectDevicesRefreshTask = refreshTask
        isRefreshingConnectDevices = true
        defer {
            isRefreshingConnectDevices = false
            connectDevicesRefreshTask = nil
        }
        do {
            connectDevices = try await refreshTask.value
            lastConnectDevicesRefreshAt = clock.now
            refreshTrayOutputSymbol()
        } catch {
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
