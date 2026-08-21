import Foundation

@MainActor
extension PlaybackSessionViewModel {
    func transferPlayback(toConnectDevice selectedDeviceID: String) async {
        let shouldPlay: Bool
        switch connectionState {
        case .playing:
            shouldPlay = true
        default:
            shouldPlay = false
        }
        do {
            try await performPrioritizedControlCommand {
                try await self.performTransfer(deviceID: selectedDeviceID, play: shouldPlay, origin: .userManualConnect)
            }
            setActivePlaybackDeviceID(selectedDeviceID)
            hasTransferredPlaybackToCurrentDevice = selectedDeviceID == deviceID
            noteLocalPlaybackMutation()
            await syncTransportFromSpotify()
            await refreshConnectDevices(force: true)
        } catch {
            setConnectionState(.error(Self.displayError(for: error)))
        }
    }

    /// Runs a Spotify Web API control call while deferring `syncTransportFromSpotify()` reads so
    /// `GET /v1/me/player` does not race overlapping `PUT`/`POST` playback commands.
    func performPrioritizedControlCommand(_ operation: () async throws -> Void) async rethrows {
        controlCommandsInFlight += 1
        defer {
            controlCommandsInFlight -= 1
            if controlCommandsInFlight == 0, transportSyncDeferredWhileControlCommandInFlight {
                transportSyncDeferredWhileControlCommandInFlight = false
                deferredTransportSyncTask?.cancel()
                deferredTransportSyncTask = nil
                scheduleTransportSync()
            }
        }
        try await operation()
    }

    /// Single-flight, idempotent, budget-aware funnel for `PUT /v1/me/player`. Returns `true`
    /// when a PUT was actually issued and `false` when the request was satisfied without one
    /// (e.g. Spotify already shows the target as the active device, or a sibling caller's
    /// in-flight transfer already covered the same intent).
    @discardableResult
    func performTransfer(deviceID: String, play: Bool, origin: TransferOrigin) async throws -> Bool {
        if let inflight = inflightTransferTask {
            // Wait for the in-flight transfer; if it satisfied this caller's intent, we're done.
            _ = try? await inflight.value
            if origin.isAutomatic, deviceID == self.deviceID, hasTransferredPlaybackToCurrentDevice {
                return false
            }
        }
        let serial = inflightTransferSerial
        inflightTransferSerial &+= 1
        let task = Task<Bool, Error> { [weak self] in
            guard let self else { return false }
            return try await self.runSingleTransfer(deviceID: deviceID, play: play, origin: origin)
        }
        inflightTransferTask = task
        activeInflightTransferSerial = serial
        defer {
            if activeInflightTransferSerial == serial {
                inflightTransferTask = nil
                activeInflightTransferSerial = nil
            }
        }
        return try await task.value
    }

    private func runSingleTransfer(deviceID: String, play: Bool, origin: TransferOrigin) async throws -> Bool {
        let alreadyActive: Bool
        switch origin {
        case .userManualConnect:
            // The Connect picker is populated from a recent `GET /v1/me/player/devices`; trust it.
            alreadyActive = connectDevices.first(where: { $0.deviceID == deviceID })?.isActive == true
        case .ensureBeforePlay, .autoResume:
            alreadyActive = latestPlayerSnapshot?.activeDevice?.deviceID == deviceID
        case .userRetry:
            // Recovery is the user's explicit ask; never short-circuit it on cached state.
            alreadyActive = false
        }
        SpotiglassLog.info(.playback, "performTransfer deviceID=\(deviceID) play=\(play) origin=\(origin) alreadyActive=\(alreadyActive) snapshotActive=\(latestPlayerSnapshot?.activeDevice?.deviceID ?? "<nil>")")
        if alreadyActive {
            if (origin == .ensureBeforePlay || origin == .autoResume), deviceID == self.deviceID {
                hasTransferredPlaybackToCurrentDevice = true
            }
            return false
        }
        if let until = transferRetryCooldownUntil, clock.now < until {
            let remaining = max(Self.durationSeconds(until - clock.now), 0.5)
            throw SpotifyAPIError.rateLimited(retryAfter: remaining)
        }
        if origin.isAutomatic {
            pruneOldTransferAttempts()
            if transferAttemptInstants.count >= autoTransferRollingWindowMax {
                let windowSeconds = Self.durationSeconds(autoTransferRollingWindow)
                throw SpotifyAPIError.rateLimited(retryAfter: windowSeconds)
            }
        }
        transferAttemptInstants.append(clock.now)
        do {
            try await playbackAPI.transferPlayback(to: deviceID, play: play)
            SpotiglassLog.info(.playback, "transferPlayback PUT ok deviceID=\(deviceID) play=\(play)")
        } catch let apiError as SpotifyAPIError {
            SpotiglassLog.error(.playback, "transferPlayback PUT failed deviceID=\(deviceID) play=\(play) error=\(apiError)")
            if case let .rateLimited(retryAfter) = apiError {
                let cooldown = retryAfter ?? Self.durationSeconds(transferDefaultCooldown)
                transferRetryCooldownUntil = clock.now.advanced(by: .seconds(cooldown))
            }
            throw apiError
        }
        if (origin == .ensureBeforePlay || origin == .autoResume), deviceID == self.deviceID {
            hasTransferredPlaybackToCurrentDevice = true
        }
        return true
    }

    private func pruneOldTransferAttempts() {
        let cutoff = clock.now.advanced(by: .zero - autoTransferRollingWindow)
        transferAttemptInstants.removeAll { $0 < cutoff }
    }

    static func durationSeconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000.0
    }

    func ensurePlaybackTransferredIfNeeded(deviceID: String) async throws {
        guard deviceID == self.deviceID else {
            SpotiglassLog.info(.playback, "ensureTransferred skipped for remote command target deviceID=\(deviceID)")
            return
        }
        guard !hasTransferredPlaybackToCurrentDevice else {
            SpotiglassLog.info(.playback, "ensureTransferred skipped (already transferred) deviceID=\(deviceID)")
            return
        }
        SpotiglassLog.info(.playback, "ensureTransferred starting deviceID=\(deviceID)")
        setConnectionState(.transferring(deviceID: deviceID))
        try await performTransfer(deviceID: deviceID, play: false, origin: .ensureBeforePlay)
    }

    /// On window reopen the previous session's `WKWebView` often lingers as the active Spotify
    /// Connect "Spotiglass" device for a few seconds. When that happens, hand playback to the
    /// freshly created device so the user keeps hearing music through the window they just
    /// reopened. Restricted to devices named ``SpotifyPlaybackHost/deviceName`` so a clean first
    /// launch never steals playback from the user's other Connect targets (phone, desktop, …).
    func autoResumeFromStaleSpotiglassDeviceIfNeeded(
        targetDeviceID: String,
        initialTransportSyncTask: Task<Void, Never>? = nil
    ) async {
        guard !hasTransferredPlaybackToCurrentDevice else { return }
        await refreshConnectDevices(force: true)
        let devices = connectDevices
        guard let staleSpotiglass = devices.first(where: { device in
            device.isActive
                && device.name == SpotifyPlaybackHost.deviceName
                && device.deviceID != targetDeviceID
        }) else {
            return
        }
        let shouldPlay = await preservedPlayState(
            for: staleSpotiglass.deviceID,
            initialTransportSyncTask: initialTransportSyncTask
        )

        do {
            setConnectionState(.transferring(deviceID: targetDeviceID))
            try await performTransfer(deviceID: targetDeviceID, play: shouldPlay, origin: .autoResume)
            // Subsequent SDK `state_changed` will move the connection state to .playing/.paused.
        } catch {
            setConnectionState(.ready(deviceID: targetDeviceID))
        }
    }

    private func preservedPlayState(
        for deviceID: String,
        initialTransportSyncTask: Task<Void, Never>?
    ) async -> Bool {
        if let initialTransportSyncTask {
            await initialTransportSyncTask.value
        } else {
            await syncTransportFromSpotify()
        }

        guard isTransportStateKnown,
              let snapshot = latestPlayerSnapshot,
              snapshot.activeDevice?.deviceID == deviceID
        else {
            // A missing, unreadable, or mismatched player snapshot must never
            // turn a paused session into a playing transfer.
            return false
        }
        return snapshot.isPlaying
    }
}
