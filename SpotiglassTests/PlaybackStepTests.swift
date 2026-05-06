import XCTest
@testable import Spotiglass

@MainActor
final class PlaybackStepTests: XCTestCase {
    func testNowPlayingArtistTapTargetsNormalizeNames() {
        let nowPlaying = PlaybackNowPlaying(
            name: "Song",
            artists: ["  Artist One  ", "artist one", "Artist Two"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 120_000,
            positionMilliseconds: 0,
            uri: "spotify:track:test"
        )

        XCTAssertEqual(nowPlaying.artistTapTargets.count, 2)
        XCTAssertEqual(nowPlaying.artistTapTargets[0].name, "Artist One")
        XCTAssertEqual(nowPlaying.artistTapTargets[1].name, "Artist Two")
        XCTAssertNil(nowPlaying.artistTapTargets[0].id)
    }

    func testBridgeParsesReadyStateAndErrors() throws {
        XCTAssertEqual(
            try SpotifyPlaybackBridgeParser.parse(["name": "ready", "payload": ["deviceID": "device-1"]]),
            .ready(deviceID: "device-1")
        )
        XCTAssertEqual(
            try SpotifyPlaybackBridgeParser.parse(["name": "account_error", "payload": ["message": "Premium required"]]),
            .accountError("Premium required")
        )
        XCTAssertThrowsError(try SpotifyPlaybackBridgeParser.parse(["name": "ready", "payload": [:]])) { error in
            XCTAssertEqual(error as? PlaybackBridgeMessageError, .missingPayload("deviceID"))
        }
    }

    func testBridgeParsesPlaybackState() throws {
        let event = try SpotifyPlaybackBridgeParser.parse([
            "name": "state_changed",
            "payload": [
                "paused": false,
                "track": [
                    "name": "Track",
                    "artists": ["Artist"],
                    "albumURI": "spotify:album:album42",
                    "albumArtURL": "https://example.com/art.png",
                    "durationMilliseconds": 180_000,
                    "positionMilliseconds": 42_000,
                    "uri": "spotify:track:1"
                ]
            ]
        ])

        guard case let .stateChanged(nowPlaying, isPaused, nextTracks) = event else {
            return XCTFail("Expected state changed")
        }
        XCTAssertFalse(isPaused)
        XCTAssertEqual(nextTracks.count, 0)
        XCTAssertEqual(nowPlaying?.name, "Track")
        XCTAssertEqual(nowPlaying?.albumID, "album42")
        XCTAssertEqual(nowPlaying?.progressText, "0:42 / 3:00")
    }

    func testBridgeParsesSpotifyAlbumIDFromURI() {
        XCTAssertEqual(SpotifyPlaybackBridgeParser.spotifyAlbumID(fromAlbumURI: nil), nil)
        XCTAssertEqual(SpotifyPlaybackBridgeParser.spotifyAlbumID(fromAlbumURI: "spotify:album:abc"), "abc")
        XCTAssertNil(SpotifyPlaybackBridgeParser.spotifyAlbumID(fromAlbumURI: "spotify:track:wrong"))
    }

    func testTokenBridgeOnlyReturnsAccessToken() async throws {
        let provider = MockPlaybackTokenProvider(accessToken: "access", refreshedAccessToken: "refreshed")
        let bridge = PlaybackTokenBridge(provider: provider)

        let response = try await bridge.tokenResponse(refresh: true)

        XCTAssertEqual(response, ["accessToken": "refreshed"])
        XCTAssertNil(response["refreshToken"])
        XCTAssertEqual(provider.refreshCount, 1)
    }

    func testPlaybackSessionTransitionsFromConnectingToReadyAndPlaying() async {
        let commander = MockWebPlaybackCommander()
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: commander)

        viewModel.start()
        viewModel.handle(.ready(deviceID: "device-1"))
        viewModel.handle(.stateChanged(PlaybackNowPlaying(
            name: "Track",
            artists: ["Artist"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 100_000,
            positionMilliseconds: 5_000,
            uri: "spotify:track:1"
        ), isPaused: false, nextTracks: []))
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(commander.didLoadHost)
        XCTAssertEqual(commander.commands.first?.command, .connect)
        XCTAssertTrue(commander.commands.contains { $0.command == .setVolume })
        XCTAssertEqual(viewModel.deviceID, "device-1")
        guard case let .playing(nowPlaying) = viewModel.connectionState else {
            return XCTFail("Expected playing")
        }
        XCTAssertEqual(nowPlaying.name, "Track")
    }

    func testReadySyncsPlaybackVolumeToWebPlayer() async {
        UserDefaults.standard.removeObject(forKey: "spotiglass.playbackVolume")
        let commander = MockWebPlaybackCommander()
        let viewModel = PlaybackSessionViewModel(playbackAPI: MockPlaybackAPI(), webCommander: commander)
        viewModel.handle(.ready(deviceID: "device-1"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        let volumeCommands = commander.commands.filter { $0.command == .setVolume }
        XCTAssertEqual(volumeCommands.count, 1)
        let sent = volumeCommands[0].payload["volume"] as? Double
        XCTAssertNotNil(sent)
        XCTAssertEqual(sent!, PlaybackSessionViewModel.defaultPlaybackVolume, accuracy: 0.001)
    }

    func testSetPlaybackVolumePersistsAndSendsBridgeCommand() async {
        let commander = MockWebPlaybackCommander()
        let viewModel = PlaybackSessionViewModel(playbackAPI: MockPlaybackAPI(), webCommander: commander)
        viewModel.setPlaybackVolume(0.56)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(viewModel.playbackVolume, 0.56, accuracy: 0.000_001)
        XCTAssertEqual(commander.commands.last?.command, .setVolume)
        let lastVolume = commander.commands.last?.payload["volume"] as? Double
        XCTAssertNotNil(lastVolume)
        XCTAssertEqual(lastVolume!, 0.56, accuracy: 0.000_001)
        XCTAssertEqual(UserDefaults.standard.double(forKey: "spotiglass.playbackVolume"), 0.56, accuracy: 0.000_001)
        UserDefaults.standard.removeObject(forKey: "spotiglass.playbackVolume")
    }

    func testPlayURITransfersPlaybackBeforePlayCommand() async {
        let commander = MockWebPlaybackCommander()
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: commander)
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.play(uri: "spotify:track:1")

        XCTAssertEqual(playbackAPI.actions, [
            "transfer:device-1:false",
            "play:device-1:spotify:track:1"
        ])
        XCTAssertEqual(commander.commands.last?.command, .playURI)
        XCTAssertEqual(commander.commands.last?.payload["uri"] as? String, "spotify:track:1")
    }

    func testPlayURIDoesNotTransferAgainForConsecutiveTrackSwitchesOnSameDevice() async {
        let commander = MockWebPlaybackCommander()
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: commander)
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.play(uri: "spotify:track:1")
        await viewModel.play(uri: "spotify:track:2")

        XCTAssertEqual(playbackAPI.actions, [
            "transfer:device-1:false",
            "play:device-1:spotify:track:1",
            "play:device-1:spotify:track:2"
        ])
    }

    func testPlayURITransfersAgainAfterDeviceBecomesNotReady() async {
        let commander = MockWebPlaybackCommander()
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: commander)
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.play(uri: "spotify:track:1")
        viewModel.handle(.notReady(deviceID: "device-1"))
        viewModel.handle(.ready(deviceID: "device-1"))
        await viewModel.play(uri: "spotify:track:2")

        XCTAssertEqual(playbackAPI.actions, [
            "transfer:device-1:false",
            "play:device-1:spotify:track:1",
            "transfer:device-1:false",
            "play:device-1:spotify:track:2"
        ])
    }

    func testNextPreviousAndSeekUseWebAPIOnly() async {
        let commander = MockWebPlaybackCommander()
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: commander)
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.next()
        await viewModel.previous()
        await viewModel.seek(to: 12_000)

        XCTAssertEqual(playbackAPI.actions, [
            "next:device-1",
            "previous:device-1",
            "seek:device-1:12000"
        ])
        try? await Task.sleep(nanoseconds: 100_000_000)
        let transportBridgeCommands = commander.commands.filter { $0.command != .setVolume }
        XCTAssertTrue(
            transportBridgeCommands.isEmpty,
            "Transport commands should not be mirrored to the Web Playback SDK."
        )
    }

    func testCycleRepeatAdvancesRepeatMode() async {
        let api = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: api,
            webCommander: MockWebPlaybackCommander(),
            postRepeatSyncDelay: .milliseconds(20)
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        XCTAssertEqual(viewModel.repeatMode, .off)

        await viewModel.cycleRepeat()

        XCTAssertEqual(viewModel.repeatMode, .context)
        XCTAssertTrue(api.actions.contains("setRepeat:device-1:context"))
        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertTrue(api.actions.contains("fetchPlayerSnapshot"), "Background transport sync should run after repeat toggle.")
    }

    func testCycleRepeatRevertsWhenSetRepeatFails() async {
        let api = MockPlaybackAPI()
        api.setRepeatError = SpotifyAPIError.notFound(message: nil)
        let viewModel = PlaybackSessionViewModel(playbackAPI: api, webCommander: MockWebPlaybackCommander())
        viewModel.handle(.ready(deviceID: "device-1"))
        XCTAssertEqual(viewModel.repeatMode, .off)

        await viewModel.cycleRepeat()

        XCTAssertEqual(viewModel.repeatMode, .off)
        guard case .error = viewModel.connectionState else {
            return XCTFail("Expected error state after failed setRepeat")
        }
    }

    func testRepeatSyncIgnoresStaleTransportWhilePending() async {
        let api = MockPlaybackAPI()
        api.transportResponses = [
            SpotifyPlayerTransport(shuffle: false, repeatMode: .off)
        ]
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: api,
            webCommander: MockWebPlaybackCommander(),
            pendingRepeatTimeout: .seconds(5),
            postRepeatSyncDelay: .seconds(10)
        )
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.cycleRepeat()
        XCTAssertEqual(viewModel.repeatMode, .context)

        await viewModel.syncTransportFromSpotify()
        XCTAssertEqual(viewModel.repeatMode, .context, "Stale transport read should not overwrite optimistic repeat while pending.")
    }

    func testRepeatPendingClearsWhenTransportMatchesExpectedMode() async {
        let api = MockPlaybackAPI()
        api.transportResponses = [
            SpotifyPlayerTransport(shuffle: false, repeatMode: .off),
            SpotifyPlayerTransport(shuffle: false, repeatMode: .context),
            SpotifyPlayerTransport(shuffle: false, repeatMode: .off)
        ]
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: api,
            webCommander: MockWebPlaybackCommander(),
            pendingRepeatTimeout: .seconds(5),
            postRepeatSyncDelay: .seconds(10)
        )
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.cycleRepeat()
        XCTAssertEqual(viewModel.repeatMode, .context)

        await viewModel.syncTransportFromSpotify()
        XCTAssertEqual(viewModel.repeatMode, .context, "First stale read should be suppressed.")

        await viewModel.syncTransportFromSpotify()
        XCTAssertEqual(viewModel.repeatMode, .context, "Matching transport should keep mode and clear pending suppression.")

        await viewModel.syncTransportFromSpotify()
        XCTAssertEqual(viewModel.repeatMode, .off, "After pending clears, transport reads apply normally.")
    }

    func testRepeatPendingTimeoutEventuallyAcceptsTransportValue() async {
        let api = MockPlaybackAPI()
        api.transportResponses = [
            SpotifyPlayerTransport(shuffle: false, repeatMode: .off)
        ]
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: api,
            webCommander: MockWebPlaybackCommander(),
            pendingRepeatTimeout: .milliseconds(50),
            postRepeatSyncDelay: .seconds(10)
        )
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.cycleRepeat()
        XCTAssertEqual(viewModel.repeatMode, .context)

        try? await Task.sleep(nanoseconds: 90_000_000)
        await viewModel.syncTransportFromSpotify()
        XCTAssertEqual(viewModel.repeatMode, .off, "After timeout, transport value should be accepted to avoid long-lived drift.")
    }

    func testToggleShuffleFlipsShuffleEnabled() async {
        let api = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: api,
            webCommander: MockWebPlaybackCommander(),
            postShuffleSyncDelay: .milliseconds(20)
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        XCTAssertFalse(viewModel.shuffleEnabled)

        await viewModel.toggleShuffle()

        XCTAssertTrue(viewModel.shuffleEnabled)
        XCTAssertTrue(api.actions.contains("setShuffle:device-1:true"))
        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertTrue(api.actions.contains("fetchPlayerSnapshot"))
    }

    func testToggleShuffleRevertsWhenSetShuffleFails() async {
        let api = MockPlaybackAPI()
        api.setShuffleError = SpotifyAPIError.notFound(message: nil)
        let viewModel = PlaybackSessionViewModel(playbackAPI: api, webCommander: MockWebPlaybackCommander())
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.toggleShuffle()

        XCTAssertFalse(viewModel.shuffleEnabled)
        guard case .error = viewModel.connectionState else {
            return XCTFail("Expected error state after failed setShuffle")
        }
    }

    func testShuffleSyncIgnoresStaleTransportWhilePending() async {
        let api = MockPlaybackAPI()
        api.transportResponses = [SpotifyPlayerTransport(shuffle: false, repeatMode: .off)]
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: api,
            webCommander: MockWebPlaybackCommander(),
            pendingShuffleTimeout: .seconds(5),
            postShuffleSyncDelay: .seconds(10)
        )
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.toggleShuffle()
        XCTAssertTrue(viewModel.shuffleEnabled)

        await viewModel.syncTransportFromSpotify()
        XCTAssertTrue(viewModel.shuffleEnabled, "Stale shuffle transport read should not overwrite optimistic local state while pending.")
    }

    func testShufflePendingClearsWhenTransportMatchesExpectedState() async {
        let api = MockPlaybackAPI()
        api.transportResponses = [
            SpotifyPlayerTransport(shuffle: false, repeatMode: .off),
            SpotifyPlayerTransport(shuffle: true, repeatMode: .off),
            SpotifyPlayerTransport(shuffle: false, repeatMode: .off)
        ]
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: api,
            webCommander: MockWebPlaybackCommander(),
            pendingShuffleTimeout: .seconds(5),
            postShuffleSyncDelay: .seconds(10)
        )
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.toggleShuffle()
        XCTAssertTrue(viewModel.shuffleEnabled)

        await viewModel.syncTransportFromSpotify()
        XCTAssertTrue(viewModel.shuffleEnabled, "First stale read should be suppressed while pending.")

        await viewModel.syncTransportFromSpotify()
        XCTAssertTrue(viewModel.shuffleEnabled, "Matching read should clear pending without changing state.")

        await viewModel.syncTransportFromSpotify()
        XCTAssertFalse(viewModel.shuffleEnabled, "After pending clears, transport reads apply normally.")
    }

    func testShufflePendingTimeoutEventuallyAcceptsTransportValue() async {
        let api = MockPlaybackAPI()
        api.transportResponses = [SpotifyPlayerTransport(shuffle: false, repeatMode: .off)]
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: api,
            webCommander: MockWebPlaybackCommander(),
            pendingShuffleTimeout: .milliseconds(50),
            postShuffleSyncDelay: .seconds(10)
        )
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.toggleShuffle()
        XCTAssertTrue(viewModel.shuffleEnabled)

        try? await Task.sleep(nanoseconds: 90_000_000)
        await viewModel.syncTransportFromSpotify()
        XCTAssertFalse(viewModel.shuffleEnabled, "After timeout, transport shuffle should be accepted to avoid drift.")
    }

    func testRetryPlaybackTransferCallsTransferAPIWhenDeviceKnown() async {
        let commander = MockWebPlaybackCommander()
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: commander)
        viewModel.handle(.ready(deviceID: "device-1"))
        viewModel.handle(.playbackError("Slow down"))

        await viewModel.retryPlaybackTransfer()

        XCTAssertEqual(playbackAPI.actions, ["transfer:device-1:false"])
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

    func testPlayingStateProgressAdvancesBetweenBridgeStateUpdates() async {
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander(),
            progressTickInterval: 0.02
        )
        viewModel.handle(.stateChanged(PlaybackNowPlaying(
            name: "Track",
            artists: ["Artist"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 5_000,
            uri: "spotify:track:1"
        ), isPaused: false, nextTracks: []))

        try? await Task.sleep(nanoseconds: 120_000_000)

        guard case let .playing(nowPlaying) = viewModel.connectionState else {
            return XCTFail("Expected playing state")
        }
        XCTAssertGreaterThan(nowPlaying.positionMilliseconds, 5_000)
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

        await viewModel.playFromPlaylist(
            clickedURI: "spotify:track:2",
            playableURIs: [
                "spotify:track:1",
                "spotify:track:2",
                "spotify:episode:3",
                "spotify:track:4"
            ]
        )

        XCTAssertEqual(playbackAPI.actions, [
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

        await viewModel.playFromPlaylist(
            clickedURI: "spotify:episode:2",
            playableURIs: [
                "spotify:track:1",
                "spotify:episode:2",
                "spotify:track:3"
            ]
        )

        XCTAssertEqual(playbackAPI.actions, [
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

        XCTAssertEqual(playbackAPI.actions, [
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

@MainActor
private final class MockPlaybackTokenProvider: PlaybackAccessTokenProviding {
    let accessToken: String
    let refreshedAccessToken: String
    private(set) var refreshCount = 0

    init(accessToken: String, refreshedAccessToken: String) {
        self.accessToken = accessToken
        self.refreshedAccessToken = refreshedAccessToken
    }

    func playbackAccessToken() async throws -> String {
        accessToken
    }

    func refreshedPlaybackAccessToken() async throws -> String {
        refreshCount += 1
        return refreshedAccessToken
    }
}

private final class MockWebPlaybackCommander: WebPlaybackCommanding {
    struct SentCommand {
        let command: PlaybackBridgeCommand
        let payload: [String: Any]
    }

    private(set) var didLoadHost = false
    private(set) var commands: [SentCommand] = []

    func loadHost() {
        didLoadHost = true
    }

    func send(_ command: PlaybackBridgeCommand, payload: [String: Any]) async throws {
        commands.append(SentCommand(command: command, payload: payload))
    }
}

private final class MockPlaybackAPI: SpotifyPlaybackControlling {
    private(set) var actions: [String] = []
    /// Returned by `fetchPlayerSnapshot`; updated when mock `setShuffle` / `setRepeat` succeed so background sync matches optimistic UI.
    private var reportedTransport = SpotifyPlayerTransport(shuffle: false, repeatMode: .off)
    /// Optional transport snapshots returned before `reportedTransport`; useful for simulating stale reads.
    var transportResponses: [SpotifyPlayerTransport?] = []
    /// Optional full player snapshots (supersedes `reportedTransport` / `activeConnectDevice` when non-empty).
    var snapshotResponses: [SpotifyPlayerSnapshot?] = []
    var activeConnectDevice: SpotifyConnectDevice?
    var availableDevices: [SpotifyConnectDevice] = []
    var setShuffleError: Error?
    var setRepeatError: Error?

    func transferPlayback(to deviceID: String, play: Bool) async throws {
        actions.append("transfer:\(deviceID):\(play)")
    }

    func play(uri: String, deviceID: String) async throws {
        actions.append("play:\(deviceID):\(uri)")
    }

    func play(contextURI: String, deviceID: String) async throws {
        actions.append("play-context:\(deviceID):\(contextURI)")
    }

    func play(uris: [String], deviceID: String) async throws {
        actions.append("play-list:\(deviceID):\(uris.joined(separator: ","))")
    }

    func pause(deviceID: String) async throws {
        actions.append("pause:\(deviceID)")
    }

    func resume(deviceID: String) async throws {
        actions.append("resume:\(deviceID)")
    }

    func seek(to milliseconds: Int, deviceID: String) async throws {
        actions.append("seek:\(deviceID):\(milliseconds)")
    }

    func next(deviceID: String) async throws {
        actions.append("next:\(deviceID)")
    }

    func previous(deviceID: String) async throws {
        actions.append("previous:\(deviceID)")
    }

    var queueResponse = SpotifyQueueResponse(currentlyPlaying: nil, queue: [])

    func fetchQueue() async throws -> SpotifyQueueResponse {
        actions.append("fetchQueue")
        return queueResponse
    }

    func addToQueue(uri: String, deviceID: String) async throws {
        actions.append("addToQueue:\(deviceID):\(uri)")
    }

    func fetchPlayerTransport() async throws -> SpotifyPlayerTransport? {
        actions.append("fetchPlayerTransport")
        if !transportResponses.isEmpty {
            return transportResponses.removeFirst()
        }
        return reportedTransport
    }

    func fetchPlayerSnapshot() async throws -> SpotifyPlayerSnapshot? {
        actions.append("fetchPlayerSnapshot")
        if !snapshotResponses.isEmpty {
            return snapshotResponses.removeFirst()
        }
        if !transportResponses.isEmpty {
            let transport = transportResponses.removeFirst()
            guard let transport else { return nil }
            return SpotifyPlayerSnapshot(transport: transport, activeDevice: activeConnectDevice)
        }
        return SpotifyPlayerSnapshot(transport: reportedTransport, activeDevice: activeConnectDevice)
    }

    func fetchAvailableDevices() async throws -> [SpotifyConnectDevice] {
        actions.append("fetchAvailableDevices")
        return availableDevices
    }

    func setShuffle(enabled: Bool, deviceID: String) async throws {
        if let setShuffleError { throw setShuffleError }
        actions.append("setShuffle:\(deviceID):\(enabled)")
        reportedTransport = SpotifyPlayerTransport(shuffle: enabled, repeatMode: reportedTransport.repeatMode)
    }

    func setRepeat(mode: SpotifyRepeatMode, deviceID: String) async throws {
        if let setRepeatError { throw setRepeatError }
        actions.append("setRepeat:\(deviceID):\(mode.rawValue)")
        reportedTransport = SpotifyPlayerTransport(shuffle: reportedTransport.shuffle, repeatMode: mode)
    }
}
