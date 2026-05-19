import XCTest
@testable import Spotiglass

@MainActor
final class PlaybackSessionPlayCommandsAndTrayTests: XCTestCase {
    func testPlayURIWithoutDeviceSetsPlaybackError() async {
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander()
        )
        await viewModel.play(uri: "spotify:track:1")
        guard case .error = viewModel.connectionState else {
            return XCTFail("Expected error when device is not ready")
        }
    }

    func testPlayContextURISendsAPIAndBridge() async {
        let api = MockPlaybackAPI()
        let commander = MockWebPlaybackCommander()
        let viewModel = PlaybackSessionViewModel(playbackAPI: api, webCommander: commander)
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.play(contextURI: "spotify:album:album-1")

        XCTAssertTrue(api.actions.contains("play-context:device-1:spotify:album:album-1"))
        XCTAssertEqual(commander.commands.last?.command, .playURI)
        XCTAssertEqual(commander.commands.last?.payload["uri"] as? String, "spotify:album:album-1")
    }

    func testPlayFromPlaylistFallsBackToSingleURIWhenTrackMissingFromList() async {
        let api = MockPlaybackAPI()
        let commander = MockWebPlaybackCommander()
        let viewModel = PlaybackSessionViewModel(playbackAPI: api, webCommander: commander)
        viewModel.handle(.ready(deviceID: "device-1"))
        viewModel.handle(.stateChanged(
            PlaybackNowPlaying(
                name: "Seed",
                artists: ["A"],
                albumName: nil,
                albumID: nil,
                albumArtURL: nil,
                durationMilliseconds: 100_000,
                positionMilliseconds: 0,
                uri: "spotify:track:seed"
            ),
            isPaused: false,
            nextTracks: []
        ))

        await viewModel.playFromPlaylist(
            clickedURI: "spotify:track:missing",
            playableURIs: ["spotify:track:other"],
            playlistID: "playlist-1"
        )

        XCTAssertTrue(api.actions.contains("play:device-1:spotify:track:missing"))
    }

    func testShouldSuppressStaleStateChangeUntilPendingPlayMatchesOrTimesOut() {
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander(),
            pendingShuffleTimeout: .seconds(2)
        )
        viewModel.beginPendingPlay(uri: "spotify:track:pending")
        let stale = PlaybackNowPlaying(
            name: "Old",
            artists: [],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 60_000,
            positionMilliseconds: 0,
            uri: "spotify:track:other"
        )
        XCTAssertTrue(viewModel.shouldSuppressStaleStateChange(nowPlaying: stale))

        let matching = PlaybackNowPlaying(
            name: "Pending",
            artists: [],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 60_000,
            positionMilliseconds: 0,
            uri: "spotify:track:pending"
        )
        XCTAssertFalse(viewModel.shouldSuppressStaleStateChange(nowPlaying: matching))
        XCTAssertNil(viewModel.pendingPlayURI)
    }

    func testRefreshTrayOutputSymbolUsesActiveConnectDevice() {
        let mac = MockMacAudioOutputProvider(displayName: "MacBook Speakers")
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander(),
            macAudioOutput: mac
        )
        viewModel.handle(.ready(deviceID: "local-device"))
        viewModel.latestPlayerSnapshot = SpotifyPlayerSnapshot(
            transport: SpotifyPlayerTransport(shuffle: false, repeatMode: .off),
            activeDevice: SpotifyConnectDevice(
                deviceID: "remote",
                isActive: true,
                isRestricted: false,
                name: "Living Room",
                type: "speaker"
            ),
            isPlaying: true
        )
        viewModel.refreshTrayOutputSymbol()
        XCTAssertNotEqual(viewModel.trayOutputSymbolName, "headphones")

        viewModel.latestPlayerSnapshot = SpotifyPlayerSnapshot(
            transport: SpotifyPlayerTransport(shuffle: false, repeatMode: .off),
            activeDevice: SpotifyConnectDevice(
                deviceID: "local-device",
                isActive: true,
                isRestricted: false,
                name: "Spotiglass",
                type: "computer"
            ),
            isPlaying: true
        )
        viewModel.refreshTrayOutputSymbol()
        XCTAssertNotEqual(viewModel.trayOutputSymbolName, "headphones")
    }

    func testRefreshTrayOutputSymbolFallsBackToHeadphonesWithoutDevices() {
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander(),
            macAudioOutput: MockMacAudioOutputProvider(displayName: "")
        )
        viewModel.refreshTrayOutputSymbol()
        XCTAssertEqual(viewModel.trayOutputSymbolName, "headphones")
    }
}

private final class MockMacAudioOutputProvider: MacDefaultAudioOutputProviding {
    let currentOutputDisplayName: String
    init(displayName: String) { currentOutputDisplayName = displayName }
    func startListening(_ onChange: @escaping () -> Void) {}
    func stopListening() {}
}
