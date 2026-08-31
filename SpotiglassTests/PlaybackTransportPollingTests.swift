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

    func testRemoteSnapshotDrivesPlayingTransportWithInterpolatedProgress() async {
        let playbackAPI = MockPlaybackAPI()
        let remoteDevice = SpotifyConnectDevice(
            deviceID: "phone-device",
            isActive: true,
            isRestricted: false,
            name: "Phone",
            type: "smartphone"
        )
        let remoteTrack = SpotifyTrack(
            id: "remote-track",
            name: "Remote song",
            artists: ["Remote artist"],
            albumArtworkURL: URL(string: "https://example.com/remote.png"),
            albumName: "Remote album",
            albumID: "remote-album",
            durationMilliseconds: 180_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "spotify:track:remote-track"
        )
        playbackAPI.snapshotResponses = [SpotifyPlayerSnapshot(
            transport: SpotifyPlayerTransport(shuffle: false, repeatMode: .off),
            activeDevice: remoteDevice,
            isPlaying: true,
            item: .track(remoteTrack),
            progressMilliseconds: 42_000
        )]
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander()
        )
        viewModel.deviceID = "local-device"
        viewModel.setConnectionState(.ready(deviceID: "local-device"))

        await viewModel.syncTransportFromSpotify()

        guard case let .playing(nowPlaying) = viewModel.connectionState else {
            return XCTFail("Expected remote playback to publish a playing transport state")
        }
        XCTAssertEqual(nowPlaying.name, "Remote song")
        XCTAssertEqual(nowPlaying.artistText, "Remote artist")
        XCTAssertEqual(nowPlaying.albumArtURL?.absoluteString, "https://example.com/remote.png")
        XCTAssertEqual(nowPlaying.positionMilliseconds, 42_000)
        XCTAssertEqual(viewModel.activePlaybackDeviceID, "phone-device")
        XCTAssertTrue(viewModel.isRemotePlaybackActive)
        XCTAssertTrue(viewModel.progressAnchor?.isAdvancing == true)
        XCTAssertEqual(viewModel.progressAnchor?.positionMilliseconds, 42_000)

        viewModel.handle(.stateChanged(
            PlaybackNowPlaying(
                name: "Idle SDK track",
                artists: ["Local artist"],
                albumName: nil,
                albumID: nil,
                albumArtURL: nil,
                durationMilliseconds: 90_000,
                positionMilliseconds: 0,
                uri: "spotify:track:local"
            ),
            isPaused: true,
            nextTracks: []
        ))
        XCTAssertEqual(viewModel.currentNowPlaying?.uri, "spotify:track:remote-track")
    }

    func testLocalSDKStateRemainsAuthoritativeWhenSnapshotContainsItem() async {
        let playbackAPI = MockPlaybackAPI()
        let localDevice = SpotifyConnectDevice(
            deviceID: "local-device",
            isActive: true,
            isRestricted: false,
            name: "Spotiglass",
            type: "computer"
        )
        let snapshotTrack = PlaylistBrowsingTestFixtures.fallbackTrack(
            id: "snapshot-track",
            name: "Snapshot track",
            artistId: "snapshot-artist"
        )
        playbackAPI.snapshotResponses = [SpotifyPlayerSnapshot(
            transport: SpotifyPlayerTransport(shuffle: false, repeatMode: .off),
            activeDevice: localDevice,
            isPlaying: true,
            item: .track(snapshotTrack),
            progressMilliseconds: 25_000
        )]
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander()
        )
        viewModel.deviceID = "local-device"
        let sdkTrack = PlaybackNowPlaying(
            name: "SDK track",
            artists: ["SDK artist"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 100_000,
            positionMilliseconds: 7_000,
            uri: "spotify:track:sdk-track"
        )
        viewModel.setConnectionState(.playing(sdkTrack))

        await viewModel.syncTransportFromSpotify()

        XCTAssertEqual(viewModel.currentNowPlaying?.uri, "spotify:track:sdk-track")
        XCTAssertEqual(viewModel.currentNowPlaying?.positionMilliseconds, 7_000)
        XCTAssertFalse(viewModel.isRemotePlaybackActive)
    }

    func testRemoteSnapshotDrivesPausedEpisodeTransportState() async {
        let playbackAPI = MockPlaybackAPI()
        let remoteDevice = SpotifyConnectDevice(
            deviceID: "phone-device",
            isActive: true,
            isRestricted: false,
            name: "Phone",
            type: "smartphone"
        )
        let episode = SpotifyEpisode(
            id: "episode-1",
            name: "Remote episode",
            showName: "Remote show",
            artworkURL: URL(string: "https://example.com/show.png"),
            durationMilliseconds: 600_000,
            isPlayable: true,
            uri: "spotify:episode:episode-1"
        )
        playbackAPI.snapshotResponses = [SpotifyPlayerSnapshot(
            transport: SpotifyPlayerTransport(shuffle: false, repeatMode: .off),
            activeDevice: remoteDevice,
            isPlaying: false,
            item: .episode(episode),
            progressMilliseconds: 12_000
        )]
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander()
        )
        viewModel.deviceID = "local-device"
        viewModel.setConnectionState(.ready(deviceID: "local-device"))

        await viewModel.syncTransportFromSpotify()

        guard case let .paused(nowPlaying) = viewModel.connectionState else {
            return XCTFail("Expected remote episode playback to publish a paused transport state")
        }
        XCTAssertEqual(nowPlaying?.name, "Remote episode")
        XCTAssertEqual(nowPlaying?.artistText, "Remote show")
        XCTAssertEqual(nowPlaying?.positionMilliseconds, 12_000)
        XCTAssertFalse(viewModel.progressAnchor?.isAdvancing == true)
    }

    func testRemotePlayPauseCommandsTargetActiveConnectDevice() async {
        let playbackAPI = MockPlaybackAPI()
        let remoteDevice = SpotifyConnectDevice(
            deviceID: "phone-device",
            isActive: true,
            isRestricted: false,
            name: "Phone",
            type: "smartphone"
        )
        let track = PlaylistBrowsingTestFixtures.fallbackTrack(
            id: "remote-track",
            name: "Remote song",
            artistId: "remote-artist"
        )
        playbackAPI.snapshotResponses = [SpotifyPlayerSnapshot(
            transport: SpotifyPlayerTransport(shuffle: false, repeatMode: .off),
            activeDevice: remoteDevice,
            isPlaying: true,
            item: .track(track),
            progressMilliseconds: 1_000
        )]
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander()
        )
        viewModel.deviceID = "local-device"
        viewModel.setConnectionState(.ready(deviceID: "local-device"))
        await viewModel.syncTransportFromSpotify()

        XCTAssertTrue(viewModel.isPlaybackToggleReady)
        await viewModel.togglePlayPause()
        await viewModel.togglePlayPause()

        XCTAssertEqual(
            playbackAPI.actions.filter { $0 == "pause:phone-device" || $0 == "resume:phone-device" },
            ["pause:phone-device", "resume:phone-device"]
        )
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
