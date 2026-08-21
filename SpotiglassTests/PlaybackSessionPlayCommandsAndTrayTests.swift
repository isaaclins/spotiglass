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
        viewModel.pendingPlayTransition = PlaybackSessionViewModel.PendingPlayTransition(
            ownerID: nil,
            hostGeneration: viewModel.playbackHostGeneration,
            kind: .uri(expectedURI: "spotify:track:pending"),
            deadline: ContinuousClock().now.advanced(by: .seconds(30))
        )
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

    func testDedupedPlayLeavesAcceptedTransitionOwnershipUntouched() async {
        let api = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: api,
            webCommander: MockWebPlaybackCommander()
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        let oldTrack = PlaybackNowPlaying(
            name: "Old",
            artists: [],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 60_000,
            positionMilliseconds: 0,
            uri: "spotify:track:a"
        )
        let differentTrack = PlaybackNowPlaying(
            name: "Different",
            artists: [],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 60_000,
            positionMilliseconds: 0,
            uri: "spotify:track:b"
        )
        viewModel.handle(.stateChanged(oldTrack, isPaused: false, nextTracks: []))

        let playEntered = AsyncSignal()
        let releasePlay = AsyncSignal()
        api.onPlay = { _ in
            playEntered.signal()
            await releasePlay.wait()
        }

        let firstPlay = Task { await viewModel.play(uri: "spotify:track:a") }
        await playEntered.wait()
        await viewModel.play(uri: "spotify:track:a")

        viewModel.handle(.stateChanged(differentTrack, isPaused: false, nextTracks: []))
        guard case let .playing(afterDifferentTrack) = viewModel.connectionState else {
            return XCTFail("Expected the deduped call to leave the accepted play transition active")
        }
        XCTAssertEqual(afterDifferentTrack.uri, "spotify:track:a")

        viewModel.handle(.stateChanged(oldTrack, isPaused: false, nextTracks: []))
        guard case let .playing(afterMatch) = viewModel.connectionState else {
            return XCTFail("Expected the accepted URI to clear its own state fence")
        }
        XCTAssertEqual(afterMatch.uri, "spotify:track:a")

        releasePlay.signal()
        await firstPlay.value
        XCTAssertEqual(api.actions.filter { $0.hasPrefix("play:") }.count, 1)
        XCTAssertEqual(viewModel.playCommandDedupedCount, 1)
    }

    func testQueuedPlayReownsURIFenceBeforeAPICompletion() async {
        let api = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: api,
            webCommander: MockWebPlaybackCommander()
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        let oldTrack = PlaybackNowPlaying(
            name: "Old",
            artists: [],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 60_000,
            positionMilliseconds: 0,
            uri: "spotify:track:a"
        )
        let queuedTrack = PlaybackNowPlaying(
            name: "Queued",
            artists: [],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 60_000,
            positionMilliseconds: 0,
            uri: "spotify:track:b"
        )
        viewModel.handle(.stateChanged(oldTrack, isPaused: false, nextTracks: []))

        let firstPlayEntered = AsyncSignal()
        let queuedPlayEntered = AsyncSignal()
        let releaseFirstPlay = AsyncSignal()
        let releaseQueuedPlay = AsyncSignal()
        api.onPlay = { value in
            if value == "spotify:track:a" {
                firstPlayEntered.signal()
                await releaseFirstPlay.wait()
            } else if value == "spotify:track:b" {
                queuedPlayEntered.signal()
                await releaseQueuedPlay.wait()
            }
        }

        let firstPlay = Task { await viewModel.play(uri: "spotify:track:a") }
        await firstPlayEntered.wait()
        let queuedPlay = Task {
            await viewModel.playFromPlaylist(
                clickedURI: "spotify:track:b",
                playableURIs: ["spotify:track:b", "spotify:track:c"]
            )
        }
        await queuedPlayEntered.wait()

        viewModel.handle(.stateChanged(oldTrack.with(positionMilliseconds: 1_000), isPaused: false, nextTracks: []))
        guard case let .playing(afterLateOldTrack) = viewModel.connectionState else {
            return XCTFail("Expected the queued URI fence to suppress the old URI")
        }
        XCTAssertEqual(afterLateOldTrack.uri, "spotify:track:a")

        viewModel.handle(.stateChanged(queuedTrack, isPaused: false, nextTracks: []))
        guard case let .playing(afterQueuedTrack) = viewModel.connectionState else {
            return XCTFail("Expected the queued URI to clear its own fence")
        }
        XCTAssertEqual(afterQueuedTrack.uri, "spotify:track:b")

        releaseFirstPlay.signal()
        releaseQueuedPlay.signal()
        await firstPlay.value
        await queuedPlay.value
        guard case let .playing(afterCompletions) = viewModel.connectionState else {
            return XCTFail("Expected old command completion not to mutate the newer queue request")
        }
        XCTAssertEqual(afterCompletions.uri, "spotify:track:b")
    }

    func testSupersededPlayFailureDoesNotClearNewContextTransition() async {
        let api = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: api,
            webCommander: MockWebPlaybackCommander()
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        let oldTrack = PlaybackNowPlaying(
            name: "Old",
            artists: [],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 60_000,
            positionMilliseconds: 0,
            uri: "spotify:track:a"
        )
        let newTrack = PlaybackNowPlaying(
            name: "New",
            artists: [],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 60_000,
            positionMilliseconds: 0,
            uri: "spotify:track:b"
        )
        viewModel.handle(.stateChanged(oldTrack, isPaused: false, nextTracks: []))

        let firstPlayEntered = AsyncSignal()
        let contextPlayEntered = AsyncSignal()
        let releaseFirstPlay = AsyncSignal()
        let releaseContextPlay = AsyncSignal()
        api.onPlay = { value in
            if value == "spotify:track:a" {
                firstPlayEntered.signal()
                await releaseFirstPlay.wait()
            } else if value == "spotify:album:context" {
                contextPlayEntered.signal()
                await releaseContextPlay.wait()
            }
        }
        api.playErrors = [URLError(.notConnectedToInternet)]

        let firstPlay = Task { await viewModel.play(uri: "spotify:track:a") }
        await firstPlayEntered.wait()
        let contextPlay = Task { await viewModel.play(contextURI: "spotify:album:context") }
        await contextPlayEntered.wait()

        releaseFirstPlay.signal()
        await firstPlay.value
        guard case let .playing(afterFailure) = viewModel.connectionState else {
            return XCTFail("A superseded play failure must not publish over the newer context request")
        }
        XCTAssertEqual(afterFailure.uri, "spotify:track:a")

        viewModel.handle(.stateChanged(newTrack, isPaused: false, nextTracks: []))
        guard case let .playing(afterNewTrack) = viewModel.connectionState else {
            return XCTFail("Expected the newer context transition to remain owned after old failure")
        }
        XCTAssertEqual(afterNewTrack.uri, "spotify:track:b")

        releaseContextPlay.signal()
        await contextPlay.value
    }

    func testContextPlayAdmitsFirstNewTrackAndRejectsLateSupersededTrackBeforeAPICompletes() async {
        let api = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: api,
            webCommander: MockWebPlaybackCommander()
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        let oldTrack = PlaybackNowPlaying(
            name: "Old",
            artists: [],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 60_000,
            positionMilliseconds: 0,
            uri: "spotify:track:a"
        )
        let newTrack = PlaybackNowPlaying(
            name: "New",
            artists: [],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 60_000,
            positionMilliseconds: 0,
            uri: "spotify:track:b"
        )
        viewModel.handle(.stateChanged(oldTrack, isPaused: false, nextTracks: []))

        let firstPlayEntered = AsyncSignal()
        let contextPlayEntered = AsyncSignal()
        let releaseFirstPlay = AsyncSignal()
        let releaseContextPlay = AsyncSignal()
        api.onPlay = { value in
            if value == "spotify:track:a" {
                firstPlayEntered.signal()
                await releaseFirstPlay.wait()
            } else if value == "spotify:album:context" {
                contextPlayEntered.signal()
                await releaseContextPlay.wait()
            }
        }

        let firstPlay = Task { await viewModel.play(uri: "spotify:track:a") }
        await firstPlayEntered.wait()
        let contextPlay = Task { await viewModel.play(contextURI: "spotify:album:context") }
        await contextPlayEntered.wait()

        viewModel.handle(.stateChanged(newTrack, isPaused: false, nextTracks: []))
        guard case let .playing(afterNewTrack) = viewModel.connectionState else {
            return XCTFail("Expected the context's first SDK track to render immediately")
        }
        XCTAssertEqual(afterNewTrack.uri, "spotify:track:b")

        viewModel.handle(.stateChanged(
            PlaybackNowPlaying(
                name: oldTrack.name,
                artists: oldTrack.artists,
                albumName: oldTrack.albumName,
                albumID: oldTrack.albumID,
                albumArtURL: oldTrack.albumArtURL,
                durationMilliseconds: oldTrack.durationMilliseconds,
                positionMilliseconds: 1_000,
                uri: oldTrack.uri
            ),
            isPaused: false,
            nextTracks: []
        ))
        guard case let .playing(afterLateOldTrack) = viewModel.connectionState else {
            return XCTFail("Expected a stale superseded event to leave the new track visible")
        }
        XCTAssertEqual(afterLateOldTrack.uri, "spotify:track:b")

        releaseFirstPlay.signal()
        releaseContextPlay.signal()
        await firstPlay.value
        await contextPlay.value
    }

    func testContextPlayKeepsSupersededFenceUntilFirstNewTrackAfterAPICompletes() async {
        let api = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: api,
            webCommander: MockWebPlaybackCommander()
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        let oldTrack = PlaybackNowPlaying(
            name: "Old",
            artists: [],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 60_000,
            positionMilliseconds: 0,
            uri: "spotify:track:a"
        )
        let newTrack = PlaybackNowPlaying(
            name: "New",
            artists: [],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 60_000,
            positionMilliseconds: 0,
            uri: "spotify:track:b"
        )
        viewModel.handle(.stateChanged(oldTrack, isPaused: false, nextTracks: []))

        let firstPlayEntered = AsyncSignal()
        let contextPlayEntered = AsyncSignal()
        let releaseFirstPlay = AsyncSignal()
        let releaseContextPlay = AsyncSignal()
        api.onPlay = { value in
            if value == "spotify:track:a" {
                firstPlayEntered.signal()
                await releaseFirstPlay.wait()
            } else if value == "spotify:album:context" {
                contextPlayEntered.signal()
                await releaseContextPlay.wait()
            }
        }

        let firstPlay = Task { await viewModel.play(uri: "spotify:track:a") }
        await firstPlayEntered.wait()
        let contextPlay = Task { await viewModel.play(contextURI: "spotify:album:context") }
        await contextPlayEntered.wait()

        releaseContextPlay.signal()
        await contextPlay.value

        viewModel.handle(.stateChanged(oldTrack.with(positionMilliseconds: 1_000), isPaused: false, nextTracks: []))
        guard case let .playing(afterLateOldTrack) = viewModel.connectionState else {
            return XCTFail("Expected a stale event to leave the pre-transition track visible")
        }
        XCTAssertEqual(afterLateOldTrack.uri, "spotify:track:a")

        viewModel.handle(.stateChanged(newTrack, isPaused: false, nextTracks: []))
        guard case let .playing(afterNewTrack) = viewModel.connectionState else {
            return XCTFail("Expected the first new context track to render after API completion")
        }
        XCTAssertEqual(afterNewTrack.uri, "spotify:track:b")

        releaseFirstPlay.signal()
        await firstPlay.value
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
