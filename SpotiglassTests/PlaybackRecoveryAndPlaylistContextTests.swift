import XCTest
@testable import Spotiglass

@MainActor
final class PlaybackRecoveryAndPlaylistContextTests: XCTestCase {
    func testDisconnectDuringStartupRemainsDisconnectedAfterLateSDKEvents() async {
        let commander = MockWebPlaybackCommander()
        let playbackAPI = MockPlaybackAPI()
        let connectStarted = AsyncSignal()
        let releaseConnect = AsyncSignal()
        commander.onSend = { command in
            guard command == .connect else { return }
            connectStarted.signal()
            await releaseConnect.wait()
        }
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: commander)

        viewModel.start()
        let oldGeneration = viewModel.playbackHostGeneration
        let didConnectStart = await connectStarted.wait(timeout: .seconds(1))
        XCTAssertTrue(didConnectStart)

        await viewModel.disconnect()
        viewModel.handle(PlaybackBridgeEventEnvelope(event: .ready(deviceID: "old-device"), hostGeneration: oldGeneration))
        viewModel.handle(PlaybackBridgeEventEnvelope(event: .notReady(deviceID: "old-device"), hostGeneration: oldGeneration))
        viewModel.handle(PlaybackBridgeEventEnvelope(event: .initializationError("old startup failed"), hostGeneration: oldGeneration))
        releaseConnect.signal()
        await Task.yield()

        XCTAssertEqual(viewModel.connectionState, .disconnected)
        XCTAssertNil(viewModel.deviceID)
        XCTAssertFalse(viewModel.autoResumeOnNextReady)
        XCTAssertFalse(playbackAPI.actions.contains { $0.hasPrefix("transfer:") })
    }

    func testDisconnectDuringNotReadyRecoveryPreventsOldRecoveryCompletion() async {
        let commander = MockWebPlaybackCommander()
        let connectStarted = AsyncSignal()
        let releaseConnect = AsyncSignal()
        var connectCount = 0
        commander.onSend = { command in
            guard command == .connect else { return }
            connectCount += 1
            if connectCount == 1 {
                connectStarted.signal()
                await releaseConnect.wait()
            }
        }
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: commander,
            playbackHostRecoveryConnectTimeout: .milliseconds(10),
            playbackHostRecoverySoftResetTimeout: .milliseconds(10)
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        viewModel.handle(.notReady(deviceID: "device-1"))

        let didConnectStart = await connectStarted.wait(timeout: .seconds(1))
        XCTAssertTrue(didConnectStart)
        await viewModel.disconnect()
        releaseConnect.signal()
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(viewModel.connectionState, .disconnected)
        XCTAssertEqual(commander.loadHostCallCount, 0)
        XCTAssertEqual(connectCount, 1)
    }

    func testFreshStartDuringDisconnectSendPreservesNewLifecycle() async {
        let commander = MockWebPlaybackCommander()
        let disconnectStarted = AsyncSignal()
        let releaseDisconnect = AsyncSignal()
        commander.onSend = { command in
            guard command == .disconnect else { return }
            disconnectStarted.signal()
            await releaseDisconnect.wait()
        }
        let viewModel = PlaybackSessionViewModel(playbackAPI: MockPlaybackAPI(), webCommander: commander)
        viewModel.handle(.ready(deviceID: "old-device"))

        let disconnectTask = Task {
            await viewModel.disconnect()
        }
        let didDisconnectStart = await disconnectStarted.wait(timeout: .seconds(1))
        XCTAssertTrue(didDisconnectStart)

        viewModel.start()
        let newGeneration = viewModel.playbackHostGeneration
        XCTAssertEqual(viewModel.connectionState, .connecting)
        XCTAssertTrue(viewModel.autoResumeOnNextReady)
        XCTAssertEqual(commander.loadHostCallCount, 1)
        viewModel.handle(.ready(deviceID: "new-device"))
        XCTAssertEqual(viewModel.connectionState, .ready(deviceID: "new-device"))

        releaseDisconnect.signal()
        await disconnectTask.value

        XCTAssertEqual(viewModel.playbackHostGeneration, newGeneration)
        XCTAssertEqual(viewModel.connectionState, .ready(deviceID: "new-device"))
        XCTAssertEqual(viewModel.deviceID, "new-device")
    }

    func testDisconnectDuringInitializationRecoveryPreventsOldRecoveryCompletion() async {
        let commander = MockWebPlaybackCommander()
        let connectStarted = AsyncSignal()
        let releaseConnect = AsyncSignal()
        var connectCount = 0
        commander.onSend = { command in
            guard command == .connect else { return }
            connectCount += 1
            if connectCount == 1 {
                connectStarted.signal()
                await releaseConnect.wait()
            }
        }
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: commander,
            playbackHostRecoveryConnectTimeout: .milliseconds(10),
            playbackHostRecoverySoftResetTimeout: .milliseconds(10)
        )

        viewModel.handle(.initializationError("SDK init failed"))
        let didConnectStart = await connectStarted.wait(timeout: .seconds(1))
        XCTAssertTrue(didConnectStart)
        await viewModel.disconnect()
        releaseConnect.signal()
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(viewModel.connectionState, .disconnected)
        XCTAssertEqual(commander.loadHostCallCount, 0)
        XCTAssertEqual(connectCount, 1)
    }

    func testStaleConnectCompletionCannotSendIntoFreshHostGeneration() async {
        let commander = MockWebPlaybackCommander()
        let connectStarted = AsyncSignal()
        let releaseConnect = AsyncSignal()
        var blockedGeneration: PlaybackHostGeneration?
        commander.onGenerationSend = { command, generation in
            guard command == .connect, blockedGeneration == nil else { return }
            blockedGeneration = generation
            connectStarted.signal()
            await releaseConnect.wait()
        }
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: commander
        )

        viewModel.start()
        let oldGeneration = viewModel.playbackHostGeneration
        let didStart = await connectStarted.wait(timeout: .seconds(1))
        XCTAssertTrue(didStart)
        XCTAssertEqual(blockedGeneration, oldGeneration)

        await viewModel.disconnect()
        viewModel.start()
        let newGeneration = viewModel.playbackHostGeneration
        releaseConnect.signal()
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertNotEqual(oldGeneration, newGeneration)
        XCTAssertEqual(
            commander.commands.filter { $0.command == .connect }.count,
            1,
            "The stale connect must be dropped after a fresh host generation is loaded."
        )
        XCTAssertEqual(commander.commands.first(where: { $0.command == .connect })?.command, .connect)
    }

    func testExplicitReconnectCreatesFreshGenerationAndRetainsRecoveryBehavior() async {
        let commander = MockWebPlaybackCommander()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: commander,
            playbackHostRecoveryConnectTimeout: .milliseconds(10),
            playbackHostRecoverySoftResetTimeout: .milliseconds(10)
        )

        viewModel.start()
        let oldGeneration = viewModel.playbackHostGeneration
        await viewModel.disconnect()
        viewModel.start()
        let newGeneration = viewModel.playbackHostGeneration

        XCTAssertNotEqual(oldGeneration, newGeneration)
        viewModel.handle(PlaybackBridgeEventEnvelope(
            event: .ready(deviceID: "old-device"),
            hostGeneration: oldGeneration
        ))
        XCTAssertEqual(viewModel.connectionState, .connecting)
        XCTAssertNil(viewModel.deviceID)

        viewModel.handle(PlaybackBridgeEventEnvelope(
            event: .ready(deviceID: "new-device"),
            hostGeneration: newGeneration
        ))
        XCTAssertEqual(viewModel.connectionState, .ready(deviceID: "new-device"))

        viewModel.handle(PlaybackBridgeEventEnvelope(
            event: .notReady(deviceID: "new-device"),
            hostGeneration: newGeneration
        ))
        try? await Task.sleep(for: .milliseconds(60))

        XCTAssertGreaterThanOrEqual(viewModel.playbackHostReuseConnectAttemptCount, 1)
        XCTAssertTrue(commander.commands.contains { $0.command == .connect })
    }

    func testRetryPlaybackTransferCallsTransferAPIWhenDeviceKnown() async {
        let commander = MockWebPlaybackCommander()
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: commander)
        viewModel.handle(.ready(deviceID: "device-1"))
        viewModel.handle(.playbackError("Slow down"))

        await viewModel.retryPlaybackTransfer()

        XCTAssertEqual(playbackAPI.actions.filter { $0 != "fetchPlayerSnapshot" }, ["transfer:device-1:false"])
        guard case let .ready(id) = viewModel.connectionState else {
            return XCTFail("Expected ready after retry transfer")
        }
        XCTAssertEqual(id, "device-1")
        XCTAssertEqual(viewModel.deviceID, "device-1")
    }

    func testRetryPlaybackTransferWithoutDeviceStartsPlaybackHost() async {
        let commander = MockWebPlaybackCommander()
        let viewModel = PlaybackSessionViewModel(playbackAPI: MockPlaybackAPI(), webCommander: commander)

        await viewModel.retryPlaybackTransfer()

        XCTAssertEqual(viewModel.connectionState, .connecting)
        XCTAssertTrue(commander.didLoadHost)
    }

    func testRetryPlaybackTransferWithoutDeviceUsesBoundedHardReloadBudget() async {
        let commander = MockWebPlaybackCommander()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: commander,
            playbackHostHardReloadCooldown: .seconds(5),
            playbackHostRecoveryConnectTimeout: .milliseconds(10),
            playbackHostRecoverySoftResetTimeout: .milliseconds(10)
        )

        await viewModel.retryPlaybackTransfer()
        await viewModel.retryPlaybackTransfer()

        XCTAssertEqual(commander.loadHostCallCount, 1, "Second rapid recovery should be suppressed by host reload cooldown.")
        XCTAssertEqual(viewModel.playbackHostReloadAttemptCount, 1)
        XCTAssertEqual(viewModel.playbackHostReloadSuppressedCooldownCount, 1)
    }

    func testInitializationErrorRunsReuseAttemptsBeforeHardReload() async {
        let commander = MockWebPlaybackCommander()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: commander,
            playbackHostRecoveryConnectTimeout: .milliseconds(10),
            playbackHostRecoverySoftResetTimeout: .milliseconds(10)
        )

        viewModel.handle(.initializationError("SDK init failed"))
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline,
              viewModel.playbackHostReuseConnectAttemptCount < 1 || commander.loadHostCallCount < 1 {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertGreaterThanOrEqual(viewModel.playbackHostReuseConnectAttemptCount, 1)
        XCTAssertGreaterThanOrEqual(viewModel.playbackHostReuseSoftResetAttemptCount, 1)
        XCTAssertEqual(commander.loadHostCallCount, 1, "Transient init recovery should escalate to a single hard reload after reuse attempts.")
    }

    func testPremiumAccountErrorMapsToClearState() {
        let viewModel = PlaybackSessionViewModel(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander())

        viewModel.handle(.accountError("Premium required"))

        guard case let .error(error) = viewModel.connectionState else {
            return XCTFail("Expected error")
        }
        XCTAssertEqual(error.title, "Spotify Premium required")
        XCTAssertEqual(error.message, "Premium required")
        XCTAssertNil(error.recoveryAction)
    }

    func testUnavailableDeviceStateIsExplicit() {
        let viewModel = PlaybackSessionViewModel(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander())
        viewModel.handle(.ready(deviceID: "device-1"))

        viewModel.handle(.notReady(deviceID: "device-1"))

        XCTAssertNil(viewModel.deviceID)
        guard case let .unavailable(message) = viewModel.connectionState else {
            return XCTFail("Expected unavailable")
        }
        XCTAssertTrue(message.contains("no longer available"))
    }

    func testStartReconnectsFromErrorAndUnavailableStates() async {
        let commander = MockWebPlaybackCommander()
        let viewModel = PlaybackSessionViewModel(playbackAPI: MockPlaybackAPI(), webCommander: commander)

        // Simulate a Play attempt before the SDK reported a device:
        // the view model lands in the "device unavailable" error state.
        await viewModel.play(uri: "spotify:track:1")
        guard case let .error(displayError) = viewModel.connectionState else {
            return XCTFail("Expected error after play without device")
        }
        XCTAssertEqual(displayError.title, "Playback device unavailable")

        // Choosing Reconnect from the error state must restart the SDK host.
        viewModel.start()
        try? await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(viewModel.connectionState, .connecting)
        XCTAssertTrue(commander.didLoadHost)
        XCTAssertEqual(commander.commands.last?.command, .connect)

        // Simulate the SDK eventually losing its device, then reconnecting again.
        viewModel.handle(.ready(deviceID: "device-1"))
        viewModel.handle(.notReady(deviceID: "device-1"))
        guard case .unavailable = viewModel.connectionState else {
            return XCTFail("Expected unavailable state after not_ready")
        }
        viewModel.start()
        XCTAssertEqual(viewModel.connectionState, .connecting)
        XCTAssertNil(viewModel.deviceID)
    }

    func testPlayURIOptimisticallyResetsPositionForKnownCurrentTrack() async {
        let commander = MockWebPlaybackCommander()
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: commander)
        viewModel.handle(.ready(deviceID: "device-1"))
        viewModel.handle(.stateChanged(PlaybackNowPlaying(
            name: "Track",
            artists: ["Artist"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 32_000,
            uri: "spotify:track:1"
        ), isPaused: false, nextTracks: []))

        await viewModel.play(uri: "spotify:track:1")

        guard case let .playing(nowPlaying) = viewModel.connectionState else {
            return XCTFail("Expected playing state")
        }
        XCTAssertEqual(nowPlaying.positionMilliseconds, 0)
        XCTAssertEqual(nowPlaying.uri, "spotify:track:1")
    }

    func testPlayFromPlaylistQueuesRemainingURIsInOrderFromClickedTrack() async {
        let commander = MockWebPlaybackCommander()
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: commander)
        viewModel.handle(.ready(deviceID: "device-1"))
        await viewModel.syncTransportFromSpotify()

        await viewModel.playFromPlaylist(
            clickedURI: "spotify:track:2",
            playableURIs: [
                "spotify:track:1",
                "spotify:track:2",
                "spotify:episode:3",
                "spotify:track:4"
            ]
        )

        XCTAssertEqual(playbackAPI.actions.filter { $0 != "fetchPlayerSnapshot" }, [
            "transfer:device-1:false",
            "play-list:device-1:spotify:track:2,spotify:episode:3,spotify:track:4"
        ])
        XCTAssertEqual(commander.commands.last?.payload["uri"] as? String, "spotify:track:2")
    }

    func testPlayFromPlaylistIncludesEpisodesInQueueOrder() async {
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander()
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        await viewModel.syncTransportFromSpotify()

        await viewModel.playFromPlaylist(
            clickedURI: "spotify:episode:2",
            playableURIs: [
                "spotify:track:1",
                "spotify:episode:2",
                "spotify:track:3"
            ]
        )

        XCTAssertEqual(playbackAPI.actions.filter { $0 != "fetchPlayerSnapshot" }, [
            "transfer:device-1:false",
            "play-list:device-1:spotify:episode:2,spotify:track:3"
        ])
    }

    func testPlayFromPlaylistFallsBackToSingleTrackWhenClickedURIMissing() async {
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander()
        )
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.playFromPlaylist(
            clickedURI: "spotify:track:missing",
            playableURIs: ["spotify:track:1", "spotify:track:2"]
        )

        XCTAssertEqual(playbackAPI.actions.filter { $0 != "fetchPlayerSnapshot" }, [
            "transfer:device-1:false",
            "play:device-1:spotify:track:missing"
        ])
    }

    func testActivePlaylistIDIsSetByPlayFromPlaylistAndClearedByPlayURI() async {
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander()
        )
        viewModel.handle(.ready(deviceID: "device-1"))

        XCTAssertNil(viewModel.activePlaylistID)

        await viewModel.playFromPlaylist(
            clickedURI: "spotify:track:1",
            playableURIs: ["spotify:track:1", "spotify:track:2"],
            playlistID: "playlist-42"
        )
        XCTAssertEqual(viewModel.activePlaylistID, "playlist-42")

        await viewModel.play(uri: "spotify:track:standalone")
        XCTAssertNil(viewModel.activePlaylistID)
    }

    func testPlayURISuppressesStaleStateChangedEventsForPreviousTrack() async {
        let commander = MockWebPlaybackCommander()
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: commander)
        viewModel.handle(.ready(deviceID: "device-1"))

        // Establish a current track via the SDK.
        let oldTrack = PlaybackNowPlaying(
            name: "Old",
            artists: ["A"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 200_000,
            positionMilliseconds: 50_000,
            uri: "spotify:track:old"
        )
        viewModel.handle(.stateChanged(oldTrack, isPaused: false, nextTracks: []))
        guard case let .playing(initial) = viewModel.connectionState else {
            return XCTFail("Expected .playing after initial stateChanged")
        }
        XCTAssertEqual(initial.uri, "spotify:track:old")

        // User asks to play a new track. Until the SDK confirms it, any
        // mid-transition state event still showing the old URI must be
        // suppressed so the now-playing label does not jitter back.
        await viewModel.play(uri: "spotify:track:new")

        let staleOld = oldTrack.with(positionMilliseconds: 51_000)
        viewModel.handle(.stateChanged(staleOld, isPaused: false, nextTracks: []))
        guard case let .playing(afterStale) = viewModel.connectionState else {
            return XCTFail("Expected stale event to leave previous state intact")
        }
        XCTAssertEqual(
            afterStale.uri,
            "spotify:track:old",
            "Stale event for previous track should not change the connection state because the user already requested a new track."
        )
        XCTAssertEqual(
            afterStale.positionMilliseconds,
            initial.positionMilliseconds,
            "Stale event for the previous track must not advance position either."
        )

        // Once the SDK confirms the new track, the gating clears and the
        // event is applied normally.
        let newTrack = PlaybackNowPlaying(
            name: "New",
            artists: ["B"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 0,
            uri: "spotify:track:new"
        )
        viewModel.handle(.stateChanged(newTrack, isPaused: false, nextTracks: []))
        guard case let .playing(afterNew) = viewModel.connectionState else {
            return XCTFail("Expected .playing after new track confirmed")
        }
        XCTAssertEqual(afterNew.uri, "spotify:track:new")
    }

    func testActivePlaylistIDClearedByDisconnect() async {
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander()
        )
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.playFromPlaylist(
            clickedURI: "spotify:track:1",
            playableURIs: ["spotify:track:1"],
            playlistID: "playlist-9"
        )
        XCTAssertEqual(viewModel.activePlaylistID, "playlist-9")

        await viewModel.disconnect()
        XCTAssertNil(viewModel.activePlaylistID)
    }
}
