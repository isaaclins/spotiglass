import XCTest
@testable import Spotiglass

@MainActor
final class PlaybackStepTests: XCTestCase {
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
                    "albumArtURL": "https://example.com/art.png",
                    "durationMilliseconds": 180_000,
                    "positionMilliseconds": 42_000,
                    "uri": "spotify:track:1"
                ]
            ]
        ])

        guard case let .stateChanged(nowPlaying, isPaused) = event else {
            return XCTFail("Expected state changed")
        }
        XCTAssertFalse(isPaused)
        XCTAssertEqual(nowPlaying?.name, "Track")
        XCTAssertEqual(nowPlaying?.progressText, "0:42 / 3:00")
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
            albumArtURL: nil,
            durationMilliseconds: 100_000,
            positionMilliseconds: 5_000,
            uri: "spotify:track:1"
        ), isPaused: false))
        try? await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertTrue(commander.didLoadHost)
        XCTAssertEqual(commander.commands.first?.command, .connect)
        XCTAssertEqual(viewModel.deviceID, "device-1")
        guard case let .playing(nowPlaying) = viewModel.connectionState else {
            return XCTFail("Expected playing")
        }
        XCTAssertEqual(nowPlaying.name, "Track")
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

        // Clicking Connect from the error state must restart the SDK host.
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

    func transferPlayback(to deviceID: String, play: Bool) async throws {
        actions.append("transfer:\(deviceID):\(play)")
    }

    func play(uri: String, deviceID: String) async throws {
        actions.append("play:\(deviceID):\(uri)")
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
}
