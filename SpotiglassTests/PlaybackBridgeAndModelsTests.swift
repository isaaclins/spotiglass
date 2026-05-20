import XCTest
@testable import Spotiglass

@MainActor
final class PlaybackBridgeAndModelsTests: XCTestCase {
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
        let np = try XCTUnwrap(nowPlaying)
        XCTAssertEqual(
            "\(PlaybackNowPlaying.durationText(milliseconds: np.positionMilliseconds)) / \(PlaybackNowPlaying.durationText(milliseconds: np.durationMilliseconds))",
            "0:42 / 3:00"
        )
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

    func testBridgeParsesNotReadyInitializationAndUnsupportedEvents() throws {
        XCTAssertEqual(
            try SpotifyPlaybackBridgeParser.parse(["name": "not_ready", "payload": ["deviceID": "device-2"]]),
            .notReady(deviceID: "device-2")
        )
        guard case let .initializationError(message) = try SpotifyPlaybackBridgeParser.parse([
            "name": "initialization_error",
            "payload": ["message": "SDK failed"]
        ]) else {
            return XCTFail("Expected initialization error")
        }
        XCTAssertEqual(message, "SDK failed")

        guard case let .authenticationError(authMessage) = try SpotifyPlaybackBridgeParser.parse([
            "name": "authentication_error",
            "payload": [:]
        ]) else {
            return XCTFail("Expected authentication error")
        }
        XCTAssertEqual(authMessage, "Spotify playback reported an error.")

        XCTAssertEqual(
            try SpotifyPlaybackBridgeParser.parse(["name": "log", "payload": ["message": "hello"]]),
            .log("hello")
        )

        XCTAssertThrowsError(try SpotifyPlaybackBridgeParser.parse(["name": "unknown_event", "payload": [:]])) { error in
            XCTAssertEqual(error as? PlaybackBridgeMessageError, .unsupportedEvent("unknown_event"))
        }
        XCTAssertThrowsError(try SpotifyPlaybackBridgeParser.parse(["payload": [:]])) { error in
            XCTAssertEqual(error as? PlaybackBridgeMessageError, .invalidEnvelope)
        }
    }

    func testBridgeParsesStateChangedWithEmptyTrackWindow() throws {
        let event = try SpotifyPlaybackBridgeParser.parse([
            "name": "state_changed",
            "payload": ["paused": true, "track": NSNull(), "nextTracks": []]
        ])
        guard case let .stateChanged(nowPlaying, isPaused, nextTracks) = event else {
            return XCTFail("Expected state changed")
        }
        XCTAssertNil(nowPlaying)
        XCTAssertTrue(isPaused)
        XCTAssertTrue(nextTracks.isEmpty)
    }

    func testBridgeParsesNextTracksAndPlaybackErrors() throws {
        let event = try SpotifyPlaybackBridgeParser.parse([
            "name": "state_changed",
            "payload": [
                "paused": false,
                "track": NSNull(),
                "nextTracks": [[
                    "name": "Up Next",
                    "artists": ["A"],
                    "durationMilliseconds": 60_000,
                    "positionMilliseconds": 0,
                    "uri": "spotify:track:2"
                ]]
            ]
        ])
        guard case let .stateChanged(_, _, nextTracks) = event else {
            return XCTFail("expected state changed")
        }
        XCTAssertEqual(nextTracks.count, 1)
        XCTAssertEqual(nextTracks[0].name, "Up Next")

        XCTAssertEqual(
            try SpotifyPlaybackBridgeParser.parse([
                "name": "playback_error",
                "payload": ["message": "Device busy"]
            ]),
            .playbackError("Device busy")
        )
        XCTAssertEqual(
            try SpotifyPlaybackBridgeParser.parse([
                "name": "authentication_error",
                "payload": ["message": "Token expired"]
            ]),
            .authenticationError("Token expired")
        )
    }

    func testSpotifyPlaybackHostHTMLFallbackIsNonEmpty() {
        XCTAssertFalse(SpotifyPlaybackHost.html.isEmpty)
        XCTAssertEqual(SpotifyPlaybackHost.deviceName, "Spotiglass")
    }

    func testParseNowPlayingTrimsEmptyAlbumName() throws {
        let event = try SpotifyPlaybackBridgeParser.parse([
            "name": "state_changed",
            "payload": [
                "paused": true,
                "track": [
                    "name": "Song",
                    "artists": ["A"],
                    "albumName": "   ",
                    "albumURI": "spotify:album:album1",
                    "durationMilliseconds": 1000,
                    "positionMilliseconds": 0,
                    "uri": "spotify:track:1"
                ]
            ]
        ])
        guard case let .stateChanged(nowPlaying, _, _) = event else {
            return XCTFail("expected state")
        }
        XCTAssertNil(nowPlaying?.albumName)
        XCTAssertEqual(nowPlaying?.albumID, "album1")
    }

    func testCoordinatorDispatchRejectsUnknownHandler() async {
        let bridge = PlaybackTokenBridge(provider: MockPlaybackTokenProvider(accessToken: "a", refreshedAccessToken: "b"))
        let result = await SpotifyPlaybackWebViewCoordinatorDispatch.tokenReply(
            handlerName: "unknown",
            body: [:],
            refresh: false,
            tokenBridge: bridge
        )
        XCTAssertNil(result.payload)
        XCTAssertNotNil(result.error)
    }

    func testTokenBridgeOnlyReturnsAccessToken() async throws {
        let provider = MockPlaybackTokenProvider(accessToken: "access", refreshedAccessToken: "refreshed")
        let bridge = PlaybackTokenBridge(provider: provider)

        let response = try await bridge.tokenResponse(refresh: true)

        XCTAssertEqual(response, ["accessToken": "refreshed"])
        XCTAssertNil(response["refreshToken"])
        XCTAssertEqual(provider.refreshCount, 1)
    }

}
