import XCTest
@testable import Spotiglass

@MainActor
final class PlaybackTransportPollingTests: XCTestCase {
    func testCancelledTransportPollDoesNotSyncImmediately() async {
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander()
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        await viewModel.syncTransportFromSpotify()
        let baselineFetchCount = playbackAPI.actions.filter { $0 == "fetchPlayerSnapshot" }.count

        viewModel.restartTransportPollingIfNeeded()

        let fetchCountAfterCancel = playbackAPI.actions.filter { $0 == "fetchPlayerSnapshot" }.count
        XCTAssertEqual(
            fetchCountAfterCancel,
            baselineFetchCount,
            "Cancelling the transport poll task during sleep must not trigger an immediate GET /v1/me/player."
        )
    }

    func testTransportPollingFailureDoesNotBecomePlaybackError() async {
        let playbackAPI = MockPlaybackAPI()
        playbackAPI.fetchPlayerSnapshotError = SpotifyAPIError.network("offline")
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander()
        )
        viewModel.deviceID = "device-1"
        viewModel.setConnectionState(.ready(deviceID: "device-1"))

        await viewModel.syncTransportFromSpotify()

        if case .error = viewModel.connectionState {
            XCTFail("A transport polling failure must not become a playback error.")
        }
    }

    func testPositionOnlyStateChangedDoesNotTriggerTransportFetch() async {
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander()
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        await viewModel.syncTransportFromSpotify()
        let track = PlaybackNowPlaying(
            name: "Track",
            artists: ["Artist"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 200_000,
            positionMilliseconds: 0,
            uri: "spotify:track:1"
        )
        viewModel.handle(.stateChanged(track, isPaused: false, nextTracks: []))
        let baselineFetchCount = playbackAPI.actions.filter { $0 == "fetchPlayerSnapshot" }.count

        for offset in stride(from: 1_000, through: 50_000, by: 1_000) {
            viewModel.handle(.stateChanged(
                track.with(positionMilliseconds: offset),
                isPaused: false,
                nextTracks: []
            ))
        }

        let fetchCountAfterTicks = playbackAPI.actions.filter { $0 == "fetchPlayerSnapshot" }.count
        XCTAssertEqual(
            fetchCountAfterTicks,
            baselineFetchCount,
            "SDK position ticks must not restart transport polling or issue GET /v1/me/player reads."
        )
    }

    func testPlayingPausedOscillationUsesSameTransportPollingKey() {
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander()
        )
        let track = PlaybackNowPlaying(
            name: "Track",
            artists: ["Artist"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 200_000,
            positionMilliseconds: 0,
            uri: "spotify:track:1"
        )
        viewModel.updateStableTransportTrackURI(from: .playing(track))
        XCTAssertEqual(
            viewModel.transportPollingKey(for: .playing(track)),
            viewModel.transportPollingKey(for: .paused(track))
        )
    }

    func testPlayingPausedOscillationDoesNotRestartTransportPoll() async {
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander()
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        await viewModel.syncTransportFromSpotify()
        let track = PlaybackNowPlaying(
            name: "Track",
            artists: ["Artist"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 200_000,
            positionMilliseconds: 0,
            uri: "spotify:track:1"
        )
        viewModel.handle(.stateChanged(track, isPaused: false, nextTracks: []))
        viewModel.restartTransportPollingIfNeeded()
        let baselineFetchCount = playbackAPI.actions.filter { $0 == "fetchPlayerSnapshot" }.count

        for _ in 0..<40 {
            viewModel.handle(.stateChanged(track, isPaused: true, nextTracks: []))
            viewModel.handle(.stateChanged(track, isPaused: false, nextTracks: []))
        }

        let fetchCountAfterOscillation = playbackAPI.actions.filter { $0 == "fetchPlayerSnapshot" }.count
        XCTAssertEqual(
            fetchCountAfterOscillation,
            baselineFetchCount,
            "Rapid play/pause SDK ticks must not restart transport polling or issue GET /v1/me/player reads."
        )
    }

    func testCurrentTransportPollDelayUsesViewModelState() {
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander()
        )
        let track = PlaybackNowPlaying(
            name: "Track",
            artists: ["Artist"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 200_000,
            positionMilliseconds: 0,
            uri: "spotify:track:1"
        )

        viewModel.transportRateLimitedUntil = viewModel.clock.now.advanced(by: .milliseconds(100))
        XCTAssertEqual(viewModel.currentTransportPollDelay(), .seconds(1))

        viewModel.transportRateLimitedUntil = viewModel.clock.now.advanced(by: .seconds(-1))
        XCTAssertEqual(viewModel.currentTransportPollDelay(), .seconds(20))
        XCTAssertNil(viewModel.transportRateLimitedUntil)

        viewModel.localMutationSettleTicksRemaining = 1
        XCTAssertEqual(viewModel.currentTransportPollDelay(), .seconds(1))
        viewModel.localMutationSettleTicksRemaining = 0

        viewModel.beginPendingPlaybackVolumeMutation(target: 0.5)
        XCTAssertEqual(viewModel.currentTransportPollDelay(), .seconds(1))
        viewModel.pendingVolumeMutation = nil

        viewModel.transportTransientErrorCount = 3
        XCTAssertEqual(viewModel.currentTransportPollDelay(), .seconds(8))
        viewModel.transportTransientErrorCount = 0

        XCTAssertEqual(viewModel.currentTransportPollDelay(), .seconds(20))

        viewModel.latestPlayerSnapshot = SpotifyPlayerSnapshot(
            transport: SpotifyPlayerTransport(shuffle: false, repeatMode: .off),
            activeDevice: nil,
            isPlaying: true
        )
        viewModel.setConnectionState(.playing(track))
        XCTAssertEqual(viewModel.currentTransportPollDelay(), .seconds(2))

        viewModel.latestPlayerSnapshot = SpotifyPlayerSnapshot(
            transport: SpotifyPlayerTransport(shuffle: false, repeatMode: .off),
            activeDevice: nil,
            isPlaying: false
        )
        viewModel.setConnectionState(.paused(track))
        XCTAssertEqual(viewModel.currentTransportPollDelay(), .seconds(8))

        viewModel.setConnectionState(.ready(deviceID: "device-1"))
        XCTAssertEqual(viewModel.currentTransportPollDelay(), .seconds(20))

        viewModel.setConnectionState(.disconnected)
        XCTAssertEqual(viewModel.currentTransportPollDelay(), .seconds(30))
    }

    func testResolvedTransportTrackURIFallsBackToStableURI() {
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander()
        )
        viewModel.stableTransportTrackURI = "spotify:track:stable"
        XCTAssertEqual(viewModel.resolvedTransportTrackURI("spotify:track:live"), "spotify:track:live")
        XCTAssertEqual(viewModel.resolvedTransportTrackURI(nil), "spotify:track:stable")
        XCTAssertEqual(viewModel.resolvedTransportTrackURI(""), "spotify:track:stable")
    }

    func testShouldRunTransportPollingRequiresDeviceAndActiveApp() {
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander()
        )
        viewModel.isAppActive = true
        XCTAssertFalse(viewModel.shouldRunTransportPolling(for: .ready(deviceID: "d")))
        viewModel.handle(.ready(deviceID: "device-1"))
        XCTAssertTrue(viewModel.shouldRunTransportPolling())
        viewModel.isAppActive = false
        XCTAssertFalse(viewModel.shouldRunTransportPolling())
    }

    func testTransportPollingKeyIgnoresPosition() {
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander()
        )
        let track = PlaybackNowPlaying(
            name: "Track",
            artists: ["Artist"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 200_000,
            positionMilliseconds: 0,
            uri: "spotify:track:1"
        )
        let playing = PlaybackConnectionState.playing(track)
        let playingAdvanced = PlaybackConnectionState.playing(track.with(positionMilliseconds: 42_000))
        XCTAssertEqual(
            viewModel.transportPollingKey(for: playing),
            viewModel.transportPollingKey(for: playingAdvanced)
        )
        XCTAssertNotEqual(playing, playingAdvanced)
    }
}
