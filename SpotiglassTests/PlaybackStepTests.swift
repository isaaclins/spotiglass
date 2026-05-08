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

    func testBridgeParsesPlayerCommandFinished() throws {
        XCTAssertEqual(
            try SpotifyPlaybackBridgeParser.parse(["name": "player_command_finished", "payload": ["command": "togglePlay"]]),
            .playerCommandFinished(command: "togglePlay")
        )
    }

    func testTogglePlayPauseSerializesUntilBridgeAck() async {
        let commander = MockWebPlaybackCommander()
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: commander)

        await viewModel.togglePlayPause()
        XCTAssertEqual(commander.commands.filter { $0.command == .togglePlay }.count, 1)

        await viewModel.togglePlayPause()
        XCTAssertEqual(commander.commands.filter { $0.command == .togglePlay }.count, 1)

        viewModel.handle(.playerCommandFinished(command: "togglePlay"))

        await viewModel.togglePlayPause()
        XCTAssertEqual(commander.commands.filter { $0.command == .togglePlay }.count, 2)
    }

    func testPlaybackErrorClearsToggleAckWait() async {
        let commander = MockWebPlaybackCommander()
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: commander)

        await viewModel.togglePlayPause()
        viewModel.handle(.playbackError("Spotify toggle failed"))

        await viewModel.togglePlayPause()
        XCTAssertEqual(commander.commands.filter { $0.command == .togglePlay }.count, 2)
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

    func testPlayCommandTriggerMatrixListsExpectedEntrypoints() {
        let matrix = PlaybackSessionViewModel.playCommandTriggerMatrix
        XCTAssertTrue(matrix.contains { $0.entrypoint == "play(uri:)" })
        XCTAssertTrue(matrix.contains { $0.entrypoint == "play(contextURI:)" })
        XCTAssertTrue(matrix.contains { $0.entrypoint == "playFromPlaylist(clickedURI:playableURIs:playlistID:)" })
    }

    func testDuplicatePlayURIWithinWindowIsDeduped() async {
        let commander = MockWebPlaybackCommander()
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: commander)
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.play(uri: "spotify:track:1")
        await viewModel.play(uri: "spotify:track:1")

        XCTAssertEqual(playbackAPI.actions, [
            "transfer:device-1:false",
            "play:device-1:spotify:track:1"
        ])
        XCTAssertEqual(viewModel.playCommandAttemptedCount, 2)
        XCTAssertEqual(viewModel.playCommandDedupedCount, 1)
        XCTAssertEqual(viewModel.playCommandSentCount, 1)
    }

    func testDifferentPlayCommandsIncrementSupersededCounterWhenOverlapping() async {
        let commander = MockWebPlaybackCommander()
        let playbackAPI = MockPlaybackAPI()
        playbackAPI.playDelayNanoseconds = 150_000_000
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: commander)
        viewModel.handle(.ready(deviceID: "device-1"))

        async let first: Void = viewModel.play(uri: "spotify:track:1")
        try? await Task.sleep(nanoseconds: 20_000_000)
        async let second: Void = viewModel.play(uri: "spotify:track:2")
        _ = await (first, second)

        XCTAssertEqual(viewModel.playCommandSentCount, 2)
        XCTAssertGreaterThanOrEqual(viewModel.playCommandSupersededCount, 1)
    }

    func testTransportSyncDefersWhilePlayCommandIsInFlight() async {
        let commander = MockWebPlaybackCommander()
        let playbackAPI = MockPlaybackAPI()
        playbackAPI.playDelayNanoseconds = 180_000_000
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: commander)
        viewModel.handle(.ready(deviceID: "device-1"))

        let playTask = Task { await viewModel.play(uri: "spotify:track:1") }
        try? await Task.sleep(nanoseconds: 20_000_000)
        await viewModel.syncTransportFromSpotify()
        XCTAssertFalse(playbackAPI.actions.contains("fetchPlayerSnapshot"))
        await playTask.value
        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertTrue(playbackAPI.actions.contains("fetchPlayerSnapshot"))
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
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: commander,
            skipCommandMinimumSpacing: .zero
        )
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.next()
        await viewModel.previous()
        await viewModel.seek(to: 12_000)

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(playbackAPI.actions.filter { $0.hasPrefix("next:") || $0.hasPrefix("previous:") || $0.hasPrefix("seek:") }, [
            "next:device-1",
            "previous:device-1",
            "seek:device-1:12000"
        ])
        let transportBridgeCommands = commander.commands.filter { $0.command != .setVolume }
        XCTAssertTrue(
            transportBridgeCommands.isEmpty,
            "Transport commands should not be mirrored to the Web Playback SDK."
        )
    }

    func testSeekCoalescesToLatestWhileRequestInFlight() async {
        let api = MockPlaybackAPI()
        api.seekDelayNanoseconds = 80_000_000
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: api,
            webCommander: MockWebPlaybackCommander(),
            seekRateLimitInterval: .milliseconds(10),
            seekDeduplicationWindowMilliseconds: 0
        )
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.seek(to: 10_000)
        await viewModel.seek(to: 20_000)
        await viewModel.seek(to: 30_000)
        try? await Task.sleep(nanoseconds: 260_000_000)

        let seeks = api.actions.filter { $0.hasPrefix("seek:") }
        XCTAssertEqual(seeks, ["seek:device-1:10000", "seek:device-1:30000"])
    }

    func testSeekRateLimitEnforcesMinimumSendSpacing() async {
        let api = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: api,
            webCommander: MockWebPlaybackCommander(),
            seekRateLimitInterval: .milliseconds(90),
            seekDeduplicationWindowMilliseconds: 0
        )
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.seek(to: 8_000)
        await viewModel.seek(to: 32_000)
        try? await Task.sleep(nanoseconds: 260_000_000)

        XCTAssertEqual(api.seekCallTimestamps.count, 2)
        let spacing = api.seekCallTimestamps[1].timeIntervalSince(api.seekCallTimestamps[0])
        XCTAssertGreaterThanOrEqual(spacing, 0.08)
    }

    func testSeekSuppressionPreventsSnapBackUntilStateCatchesUp() async {
        let api = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: api,
            webCommander: MockWebPlaybackCommander(),
            seekRateLimitInterval: .milliseconds(10),
            seekDeduplicationWindowMilliseconds: 0,
            seekMatchToleranceMilliseconds: 500
        )
        viewModel.handle(.ready(deviceID: "device-1"))

        let initialTrack = PlaybackNowPlaying(
            name: "Track",
            artists: ["Artist"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 6_000,
            uri: "spotify:track:1"
        )
        viewModel.handle(.stateChanged(initialTrack, isPaused: false, nextTracks: []))

        await viewModel.seek(to: 92_000)
        viewModel.handle(.stateChanged(initialTrack.with(positionMilliseconds: 7_000), isPaused: false, nextTracks: []))

        guard case let .playing(afterStale) = viewModel.connectionState else {
            return XCTFail("Expected playing state after stale update")
        }
        XCTAssertEqual(afterStale.positionMilliseconds, 92_000)

        viewModel.handle(.stateChanged(initialTrack.with(positionMilliseconds: 92_300), isPaused: false, nextTracks: []))
        guard case let .playing(afterMatch) = viewModel.connectionState else {
            return XCTFail("Expected playing state after matching update")
        }
        XCTAssertEqual(afterMatch.positionMilliseconds, 92_300)
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

    func testCycleRepeatRapidTapsCoalesceWritesAndConvergeToLatestIntent() async {
        let api = MockPlaybackAPI()
        api.setRepeatDelayNanoseconds = 80_000_000
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: api,
            webCommander: MockWebPlaybackCommander(),
            repeatWriteMinInterval: .milliseconds(40),
            postRepeatSyncDelay: .seconds(10)
        )
        viewModel.handle(.ready(deviceID: "device-1"))

        async let tap1: Void = viewModel.cycleRepeat() // off -> context
        async let tap2: Void = viewModel.cycleRepeat() // context -> track
        async let tap3: Void = viewModel.cycleRepeat() // track -> off
        _ = await (tap1, tap2, tap3)

        let repeatWrites = api.actions.filter { $0.hasPrefix("setRepeat:") }
        XCTAssertEqual(repeatWrites.count, 2, "Rapid repeat taps should coalesce to at most first+latest writes.")
        XCTAssertEqual(repeatWrites.first, "setRepeat:device-1:context")
        XCTAssertEqual(repeatWrites.last, "setRepeat:device-1:off")
        XCTAssertEqual(viewModel.repeatMode, .off, "Final visible repeat mode should match latest user intent.")
    }

    func testCycleRepeatRapidTapsAvoidSendingIntermediateModes() async {
        let api = MockPlaybackAPI()
        api.setRepeatDelayNanoseconds = 80_000_000
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: api,
            webCommander: MockWebPlaybackCommander(),
            repeatWriteMinInterval: .milliseconds(40),
            postRepeatSyncDelay: .seconds(10)
        )
        viewModel.handle(.ready(deviceID: "device-1"))

        async let tap1: Void = viewModel.cycleRepeat() // off -> context
        async let tap2: Void = viewModel.cycleRepeat() // context -> track
        _ = await (tap1, tap2)

        let repeatWrites = api.actions.filter { $0.hasPrefix("setRepeat:") }
        XCTAssertEqual(repeatWrites.count, 2)
        XCTAssertEqual(repeatWrites, [
            "setRepeat:device-1:context",
            "setRepeat:device-1:track"
        ])
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

    func testRapidShuffleTogglesCoalesceInFlightWrites() async {
        let api = MockPlaybackAPI()
        api.setShuffleDelayNanoseconds = 120_000_000
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: api,
            webCommander: MockWebPlaybackCommander(),
            postShuffleSyncDelay: .seconds(10)
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        XCTAssertFalse(viewModel.shuffleEnabled)

        let firstToggle = Task { await viewModel.toggleShuffle() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        let secondToggle = Task { await viewModel.toggleShuffle() }
        await firstToggle.value
        await secondToggle.value

        let shuffleWrites = api.actions.filter { $0.hasPrefix("setShuffle:") }
        XCTAssertEqual(shuffleWrites, ["setShuffle:device-1:true", "setShuffle:device-1:false"])
        XCTAssertFalse(viewModel.shuffleEnabled)
    }

    func testOlderShuffleSyncDoesNotOverrideNewerMutation() async {
        let api = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: api,
            webCommander: MockWebPlaybackCommander(),
            postShuffleSyncDelay: .seconds(10)
        )
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.toggleShuffle()
        XCTAssertTrue(viewModel.shuffleEnabled)

        // This simulates a delayed sync response from an older mutation; it
        // should be ignored instead of regressing the newer local target.
        api.transportResponses = [SpotifyPlayerTransport(shuffle: false, repeatMode: .off)]
        await viewModel.syncTransportFromSpotify(minimumShuffleMutationVersion: 0)
        XCTAssertTrue(viewModel.shuffleEnabled)
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
        try? await Task.sleep(nanoseconds: 100_000_000)

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

    func testRefreshConnectDevicesSkipsNetworkInsideFreshnessWindow() async {
        let playbackAPI = MockPlaybackAPI()
        playbackAPI.availableDevices = [
            SpotifyConnectDevice(deviceID: "a", isActive: false, isRestricted: false, name: "Mac", type: "computer", volumePercent: nil)
        ]
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander(),
            connectDevicesFreshnessWindow: .seconds(5)
        )

        await viewModel.refreshConnectDevices()
        await viewModel.refreshConnectDevices()

        let refreshCalls = playbackAPI.actions.filter { $0 == "fetchAvailableDevices" }
        XCTAssertEqual(refreshCalls.count, 1, "A second refresh inside freshness window should reuse cached device list.")
    }

    func testRefreshConnectDevicesCoalescesConcurrentRequests() async {
        let playbackAPI = MockPlaybackAPI()
        playbackAPI.fetchAvailableDevicesDelayNanoseconds = 80_000_000
        playbackAPI.availableDevices = [
            SpotifyConnectDevice(deviceID: "a", isActive: false, isRestricted: false, name: "Mac", type: "computer", volumePercent: nil)
        ]
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander(),
            connectDevicesFreshnessWindow: .seconds(0)
        )

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await viewModel.refreshConnectDevices() }
            group.addTask { await viewModel.refreshConnectDevices() }
        }

        let refreshCalls = playbackAPI.actions.filter { $0 == "fetchAvailableDevices" }
        XCTAssertEqual(refreshCalls.count, 1, "Concurrent refresh callers should share one in-flight devices request.")
    }

    func testTransferPlaybackForcesDeviceRefreshOutsideFreshnessWindow() async {
        let playbackAPI = MockPlaybackAPI()
        playbackAPI.availableDevices = [
            SpotifyConnectDevice(deviceID: "target", isActive: false, isRestricted: false, name: "Speaker", type: "speaker", volumePercent: nil)
        ]
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander(),
            connectDevicesFreshnessWindow: .seconds(30)
        )
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.refreshConnectDevices()
        await viewModel.transferPlayback(toConnectDevice: "target")

        let refreshCalls = playbackAPI.actions.filter { $0 == "fetchAvailableDevices" }
        XCTAssertEqual(refreshCalls.count, 2, "Post-transfer refresh should bypass short-term freshness TTL.")
    }

    // MARK: - Skip command (previous/next) spam guard

    func testPreviousBurstWithinCooldownIssuesSinglePOST() async {
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander(),
            skipCommandMinimumSpacing: .seconds(60)
        )
        viewModel.handle(.ready(deviceID: "device-1"))

        for _ in 0..<5 {
            await viewModel.previous()
        }

        XCTAssertEqual(
            playbackAPI.actions,
            ["previous:device-1"],
            "Burst-presses within the skip cooldown window must coalesce to a single POST /v1/me/player/previous."
        )
        XCTAssertFalse(viewModel.isSkipCommandPending)
    }

    func testNextAndPreviousShareSkipCooldownGate() async {
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander(),
            skipCommandMinimumSpacing: .seconds(60)
        )
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.previous()
        await viewModel.next()
        await viewModel.previous()
        await viewModel.next()

        XCTAssertEqual(
            playbackAPI.actions,
            ["previous:device-1"],
            "Previous and Next must share the gate so a Prev → Next → Prev burst cannot stack POSTs."
        )
    }

    func testSkipCommandsAreReleasedOnceCooldownElapses() async throws {
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander(),
            skipCommandMinimumSpacing: .milliseconds(40)
        )
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.previous()
        await viewModel.previous()
        let previousActionsAfterBurst = playbackAPI.actions.filter { $0.hasPrefix("previous:") }
        XCTAssertEqual(
            previousActionsAfterBurst,
            ["previous:device-1"],
            "Burst within the cooldown should result in exactly one POST."
        )

        try await Task.sleep(nanoseconds: 80_000_000)

        await viewModel.previous()
        let previousActionsAfterCooldown = playbackAPI.actions.filter { $0.hasPrefix("previous:") }
        XCTAssertEqual(
            previousActionsAfterCooldown,
            ["previous:device-1", "previous:device-1"],
            "Once the spacing window has elapsed, a fresh press should reach Spotify again."
        )
    }

    func testNextLocksOutUntilPlaybackURIAdvances() async {
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander(),
            skipCommandMinimumSpacing: .zero,
            skipCommandLockoutTimeout: .seconds(2)
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        viewModel.handle(.stateChanged(
            PlaybackNowPlaying(
                name: "Old",
                artists: ["Artist"],
                albumName: nil,
                albumID: nil,
                albumArtURL: nil,
                durationMilliseconds: 180_000,
                positionMilliseconds: 5_000,
                uri: "spotify:track:old"
            ),
            isPaused: false,
            nextTracks: []
        ))

        await viewModel.next()
        await viewModel.next()
        XCTAssertEqual(playbackAPI.actions.filter { $0 == "next:device-1" }.count, 1)
        XCTAssertEqual(viewModel.nextCommandDroppedLockoutCount, 1)

        viewModel.handle(.stateChanged(
            PlaybackNowPlaying(
                name: "New",
                artists: ["Artist"],
                albumName: nil,
                albumID: nil,
                albumArtURL: nil,
                durationMilliseconds: 180_000,
                positionMilliseconds: 0,
                uri: "spotify:track:new"
            ),
            isPaused: false,
            nextTracks: []
        ))
        await viewModel.next()
        XCTAssertEqual(playbackAPI.actions.filter { $0 == "next:device-1" }.count, 2)
    }

    func testNextLockoutTimeoutEventuallyAllowsAnotherDispatch() async {
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander(),
            skipCommandMinimumSpacing: .zero,
            skipCommandLockoutTimeout: .milliseconds(40)
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        viewModel.handle(.stateChanged(
            PlaybackNowPlaying(
                name: "Old",
                artists: ["Artist"],
                albumName: nil,
                albumID: nil,
                albumArtURL: nil,
                durationMilliseconds: 180_000,
                positionMilliseconds: 5_000,
                uri: "spotify:track:old"
            ),
            isPaused: false,
            nextTracks: []
        ))

        await viewModel.next()
        await viewModel.next()
        try? await Task.sleep(for: .milliseconds(70))
        await viewModel.next()

        XCTAssertEqual(playbackAPI.actions.filter { $0 == "next:device-1" }.count, 2)
        XCTAssertEqual(viewModel.nextCommandTimeoutUnlockCount, 1)
    }

    // MARK: - Transfer playback hardening (audit follow-up)

    func testConcurrentPlayRequestsCollapseToASingleTransferPUT() async {
        let playbackAPI = MockPlaybackAPI()
        // Stretch the transfer enough that two `play()` calls overlap the in-flight PUT.
        playbackAPI.transferPlaybackDelayNanoseconds = 80_000_000
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: MockWebPlaybackCommander())
        viewModel.handle(.ready(deviceID: "device-1"))

        async let first: Void = viewModel.play(uri: "spotify:track:1")
        async let second: Void = viewModel.play(uri: "spotify:track:2")
        _ = await (first, second)

        let transferActions = playbackAPI.actions.filter { $0.hasPrefix("transfer") }
        XCTAssertEqual(
            transferActions,
            ["transfer:device-1:false"],
            "Concurrent `play()` calls must funnel through a single in-flight transfer PUT."
        )
        let playActions = playbackAPI.actions.filter { $0.hasPrefix("play:") }
        XCTAssertEqual(playActions.count, 2, "Both play requests should still issue their own /v1/me/player/play call.")
    }

    func testEnsurePlaybackSkipsTransferWhenSnapshotShowsTargetDeviceActive() async {
        let playbackAPI = MockPlaybackAPI()
        playbackAPI.activeConnectDevice = SpotifyConnectDevice(
            deviceID: "device-1",
            isActive: true,
            isRestricted: false,
            name: "Spotiglass",
            type: "computer",
            volumePercent: 80
        )
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: MockWebPlaybackCommander())
        viewModel.handle(.ready(deviceID: "device-1"))
        // Prime `latestPlayerSnapshot` so the idempotency check reads a fresh active device.
        await viewModel.syncTransportFromSpotify()

        await viewModel.play(uri: "spotify:track:1")

        XCTAssertFalse(
            playbackAPI.actions.contains { $0.hasPrefix("transfer") },
            "When Spotify already reports the local device active, `play(uri:)` must not issue PUT /v1/me/player."
        )
        XCTAssertTrue(playbackAPI.actions.contains("play:device-1:spotify:track:1"))
    }

    func testManualConnectTransferSkipsWhenTargetDeviceIsAlreadyActive() async {
        let playbackAPI = MockPlaybackAPI()
        playbackAPI.availableDevices = [
            SpotifyConnectDevice(
                deviceID: "device-other",
                isActive: true,
                isRestricted: false,
                name: "Other",
                type: "speaker",
                volumePercent: 50
            )
        ]
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: MockWebPlaybackCommander())
        viewModel.handle(.ready(deviceID: "device-1"))
        // Connect picker reads `connectDevices`; populate it before the manual transfer.
        await viewModel.refreshConnectDevices(force: true)

        await viewModel.transferPlayback(toConnectDevice: "device-other")

        XCTAssertFalse(
            playbackAPI.actions.contains(where: { $0.hasPrefix("transfer:") }),
            "Picking the already-active Connect device must not issue another PUT /v1/me/player."
        )
    }

    func testRateLimitedTransferSetsCooldownAndShortCircuitsImmediateRetry() async {
        let playbackAPI = MockPlaybackAPI()
        playbackAPI.transferPlaybackErrors = [SpotifyAPIError.rateLimited(retryAfter: 5)]
        let viewModel = PlaybackSessionViewModel(playbackAPI: playbackAPI, webCommander: MockWebPlaybackCommander())
        viewModel.handle(.ready(deviceID: "device-1"))
        viewModel.handle(.notReady(deviceID: "device-1"))
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.play(uri: "spotify:track:1")

        // First attempt issues PUT and records the 429 cooldown.
        XCTAssertEqual(playbackAPI.actions.filter { $0.hasPrefix("transfer") }, ["transfer-error:device-1:false"])
        XCTAssertEqual(viewModel.transferRetryCooldownSecondsRemaining(), 5)

        await viewModel.retryPlaybackTransfer()

        // Within cooldown, the retry must short-circuit and not call the API again.
        XCTAssertEqual(
            playbackAPI.actions.filter { $0.hasPrefix("transfer") },
            ["transfer-error:device-1:false"],
            "Retry within Spotify's Retry-After window must not re-issue PUT /v1/me/player."
        )
        guard case let .error(displayError) = viewModel.connectionState else {
            return XCTFail("Expected .error after rate-limited retry")
        }
        XCTAssertEqual(displayError.recoveryAction, .retryTransfer)
    }

    func testAutomaticTransferBudgetBlocksFurtherRetriesAfterCap() async {
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander(),
            autoTransferRollingWindow: .seconds(60),
            autoTransferRollingWindowMax: 2
        )

        // Burn the auto-transfer budget with two successful ensure-before-play cycles.
        for index in 0..<2 {
            viewModel.handle(.ready(deviceID: "device-1"))
            await viewModel.play(uri: "spotify:track:\(index)")
            viewModel.handle(.notReady(deviceID: "device-1"))
        }
        // The third cycle should be rejected by the rolling-window budget.
        viewModel.handle(.ready(deviceID: "device-1"))
        await viewModel.play(uri: "spotify:track:2")

        let transferCount = playbackAPI.actions.filter { $0.hasPrefix("transfer") }.count
        XCTAssertEqual(
            transferCount, 2,
            "Automatic ensure-before-play transfers must stop after the rolling-window cap is reached."
        )
        guard case let .error(displayError) = viewModel.connectionState else {
            return XCTFail("Expected .error after the budget rejected the third automatic transfer")
        }
        XCTAssertEqual(displayError.recoveryAction, .retryTransfer)
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
    private(set) var loadHostCallCount = 0
    private(set) var commands: [SentCommand] = []

    func loadHost() {
        didLoadHost = true
        loadHostCallCount += 1
    }

    func send(_ command: PlaybackBridgeCommand, payload: [String: Any]) async throws {
        commands.append(SentCommand(command: command, payload: payload))
    }
}

private final class MockPlaybackAPI: SpotifyPlaybackControlling {
    private(set) var actions: [String] = []
    private(set) var seekCallTimestamps: [Date] = []
    /// Returned by `fetchPlayerSnapshot`; updated when mock `setShuffle` / `setRepeat` succeed so background sync matches optimistic UI.
    private var reportedTransport = SpotifyPlayerTransport(shuffle: false, repeatMode: .off)
    private var reportedIsPlaying = true
    /// Optional transport snapshots returned before `reportedTransport`; useful for simulating stale reads.
    var transportResponses: [SpotifyPlayerTransport?] = []
    /// Optional full player snapshots (supersedes `reportedTransport` / `activeConnectDevice` when non-empty).
    var snapshotResponses: [SpotifyPlayerSnapshot?] = []
    var activeConnectDevice: SpotifyConnectDevice?
    var availableDevices: [SpotifyConnectDevice] = []
    var fetchAvailableDevicesDelayNanoseconds: UInt64 = 0
    var setShuffleError: Error?
    var setRepeatError: Error?
    var playDelayNanoseconds: UInt64 = 0
    var seekDelayNanoseconds: UInt64 = 0
    var setRepeatDelayNanoseconds: UInt64 = 0
    var setShuffleDelayNanoseconds: UInt64 = 0
    /// When non-zero, `transferPlayback` sleeps before recording the action. Lets the transfer-playback audit
    /// concurrency tests overlap the in-flight PUT with a sibling caller so the single-flight guard runs.
    var transferPlaybackDelayNanoseconds: UInt64 = 0
    /// FIFO of errors thrown by `transferPlayback`. Empty queue means transfers succeed.
    var transferPlaybackErrors: [Error] = []

    func transferPlayback(to deviceID: String, play: Bool) async throws {
        if transferPlaybackDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: transferPlaybackDelayNanoseconds)
        }
        if !transferPlaybackErrors.isEmpty {
            let next = transferPlaybackErrors.removeFirst()
            actions.append("transfer-error:\(deviceID):\(play)")
            throw next
        }
        actions.append("transfer:\(deviceID):\(play)")
    }

    func play(uri: String, deviceID: String) async throws {
        if playDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: playDelayNanoseconds)
        }
        actions.append("play:\(deviceID):\(uri)")
    }

    func play(contextURI: String, deviceID: String) async throws {
        if playDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: playDelayNanoseconds)
        }
        actions.append("play-context:\(deviceID):\(contextURI)")
    }

    func play(uris: [String], deviceID: String) async throws {
        if playDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: playDelayNanoseconds)
        }
        actions.append("play-list:\(deviceID):\(uris.joined(separator: ","))")
    }

    func pause(deviceID: String) async throws {
        actions.append("pause:\(deviceID)")
    }

    func resume(deviceID: String) async throws {
        actions.append("resume:\(deviceID)")
    }

    func seek(to milliseconds: Int, deviceID: String) async throws {
        seekCallTimestamps.append(Date())
        if seekDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: seekDelayNanoseconds)
        }
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
            return SpotifyPlayerSnapshot(transport: transport, activeDevice: activeConnectDevice, isPlaying: reportedIsPlaying)
        }
        return SpotifyPlayerSnapshot(transport: reportedTransport, activeDevice: activeConnectDevice, isPlaying: reportedIsPlaying)
    }

    func fetchAvailableDevices() async throws -> [SpotifyConnectDevice] {
        actions.append("fetchAvailableDevices")
        if fetchAvailableDevicesDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: fetchAvailableDevicesDelayNanoseconds)
        }
        return availableDevices
    }

    func setShuffle(enabled: Bool, deviceID: String) async throws {
        if let setShuffleError { throw setShuffleError }
        if setShuffleDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: setShuffleDelayNanoseconds)
        }
        actions.append("setShuffle:\(deviceID):\(enabled)")
        reportedTransport = SpotifyPlayerTransport(shuffle: enabled, repeatMode: reportedTransport.repeatMode)
    }

    func setRepeat(mode: SpotifyRepeatMode, deviceID: String) async throws {
        if setRepeatDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: setRepeatDelayNanoseconds)
        }
        if let setRepeatError { throw setRepeatError }
        actions.append("setRepeat:\(deviceID):\(mode.rawValue)")
        reportedTransport = SpotifyPlayerTransport(shuffle: reportedTransport.shuffle, repeatMode: mode)
    }
}
