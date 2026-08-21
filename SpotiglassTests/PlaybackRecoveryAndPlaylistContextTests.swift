import XCTest
@testable import Spotiglass

@MainActor
final class PlaybackRecoveryAndPlaylistContextTests: XCTestCase {
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
