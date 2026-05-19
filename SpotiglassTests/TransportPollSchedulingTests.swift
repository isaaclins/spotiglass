import XCTest
@testable import Spotiglass

final class TransportPollSchedulingTests: XCTestCase {
    private let clock = ContinuousClock()

    func testTransportPollingKeyCoversDisconnectedAndErrorStates() {
        let track = sampleTrack(uri: "spotify:track:1")
        XCTAssertEqual(
            TransportPollScheduling.transportPollingKey(for: .disconnected, resolvedTrackURI: { $0 ?? "" }),
            "disconnected"
        )
        XCTAssertEqual(
            TransportPollScheduling.transportPollingKey(for: .connecting, resolvedTrackURI: { $0 ?? "" }),
            "connecting"
        )
        XCTAssertEqual(
            TransportPollScheduling.transportPollingKey(for: .ready(deviceID: "d"), resolvedTrackURI: { $0 ?? "" }),
            "ready:d"
        )
        XCTAssertEqual(
            TransportPollScheduling.transportPollingKey(for: .transferring(deviceID: "d"), resolvedTrackURI: { $0 ?? "" }),
            "transferring:d"
        )
        XCTAssertEqual(
            TransportPollScheduling.transportPollingKey(for: .playing(track), resolvedTrackURI: { $0 ?? "" }),
            "track:spotify:track:1"
        )
        XCTAssertEqual(
            TransportPollScheduling.transportPollingKey(for: .paused(.none), resolvedTrackURI: { $0 ?? "" }),
            "paused-empty"
        )
        XCTAssertEqual(
            TransportPollScheduling.transportPollingKey(
                for: .unavailable("Premium"),
                resolvedTrackURI: { $0 ?? "" }
            ),
            "unavailable:Premium"
        )
        XCTAssertEqual(
            TransportPollScheduling.transportPollingKey(
                for: .error(PlaybackDisplayError(title: "T", message: "M", recoveryAction: nil)),
                resolvedTrackURI: { $0 ?? "" }
            ),
            "error:T"
        )
    }

    func testShouldRunTransportPollingRespectsAppActiveDeviceAndMutationTicks() {
        let playing = PlaybackConnectionState.playing(sampleTrack(uri: "u"))
        XCTAssertFalse(TransportPollScheduling.shouldRunTransportPolling(
            isAppActive: false,
            deviceID: "d",
            localMutationSettleTicksRemaining: 0,
            state: playing
        ))
        XCTAssertFalse(TransportPollScheduling.shouldRunTransportPolling(
            isAppActive: true,
            deviceID: nil,
            localMutationSettleTicksRemaining: 0,
            state: playing
        ))
        XCTAssertTrue(TransportPollScheduling.shouldRunTransportPolling(
            isAppActive: true,
            deviceID: nil,
            localMutationSettleTicksRemaining: 1,
            state: .disconnected
        ))
        XCTAssertFalse(TransportPollScheduling.shouldRunTransportPolling(
            isAppActive: true,
            deviceID: "d",
            localMutationSettleTicksRemaining: 0,
            state: .connecting
        ))
        XCTAssertTrue(TransportPollScheduling.shouldRunTransportPolling(
            isAppActive: true,
            deviceID: "d",
            localMutationSettleTicksRemaining: 0,
            state: playing
        ))
    }

    func testPollDelayUsesRateLimitRemainingOrFallbackAfterExpiry() {
        let now = clock.now
        let future = now.advanced(by: .seconds(4))
        let active = TransportPollScheduling.PollDelayInputs(
            now: now,
            transportRateLimitedUntil: future,
            localMutationSettleTicksRemaining: 0,
            transportTransientErrorCount: 0,
            hasLatestPlayerSnapshot: true,
            isPlaybackActiveForPolling: true,
            connectionState: .playing(sampleTrack(uri: "u"))
        )
        XCTAssertEqual(TransportPollScheduling.pollDelay(for: active), .seconds(4))

        let expired = TransportPollScheduling.PollDelayInputs(
            now: now,
            transportRateLimitedUntil: now.advanced(by: .seconds(-1)),
            localMutationSettleTicksRemaining: 0,
            transportTransientErrorCount: 0,
            hasLatestPlayerSnapshot: true,
            isPlaybackActiveForPolling: true,
            connectionState: .playing(sampleTrack(uri: "u"))
        )
        XCTAssertEqual(TransportPollScheduling.pollDelay(for: expired), .seconds(15))
    }

    func testPollDelayBackoffPaths() {
        let now = clock.now
        let track = sampleTrack(uri: "u")
        let playing = PlaybackConnectionState.playing(track)

        var mutation = TransportPollScheduling.PollDelayInputs(
            now: now,
            transportRateLimitedUntil: nil,
            localMutationSettleTicksRemaining: 2,
            transportTransientErrorCount: 0,
            hasLatestPlayerSnapshot: true,
            isPlaybackActiveForPolling: true,
            connectionState: playing
        )
        XCTAssertEqual(TransportPollScheduling.pollDelay(for: mutation), .seconds(1))

        var transient = mutation
        transient.localMutationSettleTicksRemaining = 0
        transient.transportTransientErrorCount = 3
        XCTAssertEqual(TransportPollScheduling.pollDelay(for: transient), .seconds(8))

        var noSnapshot = transient
        noSnapshot.transportTransientErrorCount = 0
        noSnapshot.hasLatestPlayerSnapshot = false
        XCTAssertEqual(TransportPollScheduling.pollDelay(for: noSnapshot), .seconds(20))

        var pausedInactive = noSnapshot
        pausedInactive.hasLatestPlayerSnapshot = true
        pausedInactive.isPlaybackActiveForPolling = false
        pausedInactive.connectionState = .paused(track)
        XCTAssertEqual(TransportPollScheduling.pollDelay(for: pausedInactive), .seconds(8))

        var ready = pausedInactive
        ready.connectionState = .ready(deviceID: "d")
        XCTAssertEqual(TransportPollScheduling.pollDelay(for: ready), .seconds(20))

        var disconnected = ready
        disconnected.connectionState = .disconnected
        XCTAssertEqual(TransportPollScheduling.pollDelay(for: disconnected), .seconds(30))
    }

    @MainActor
    func testSyncTransportAppliesRateLimitAndTransientBackoff() async {
        let api = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(playbackAPI: api, webCommander: MockWebPlaybackCommander())
        viewModel.handle(.ready(deviceID: "device-1"))

        api.fetchPlayerSnapshotError = SpotifyAPIError.rateLimited(retryAfter: 9)
        await viewModel.syncTransportFromSpotify()
        XCTAssertNotNil(viewModel.transportRateLimitedUntil)

        api.fetchPlayerSnapshotError = SpotifyAPIError.server(statusCode: 503, message: nil, details: nil)
        await viewModel.syncTransportFromSpotify()
        XCTAssertEqual(viewModel.transportTransientErrorCount, 1)

        api.fetchPlayerSnapshotError = SpotifyAPIError.network("offline")
        await viewModel.syncTransportFromSpotify()
        XCTAssertEqual(viewModel.transportTransientErrorCount, 2)

        api.fetchPlayerSnapshotError = nil
        api.snapshotResponses = [SpotifyPlayerSnapshot(
            transport: SpotifyPlayerTransport(shuffle: false, repeatMode: .off),
            activeDevice: nil,
            isPlaying: false
        )]
        await viewModel.syncTransportFromSpotify()
        XCTAssertEqual(viewModel.transportTransientErrorCount, 0)
        XCTAssertNil(viewModel.transportRateLimitedUntil)
    }

    @MainActor
    func testSyncTransportClearsExpiredRateLimitOnSuccessfulRead() async {
        let api = MockPlaybackAPI()
        api.snapshotResponses = [
            SpotifyPlayerSnapshot(
                transport: SpotifyPlayerTransport(shuffle: false, repeatMode: .off),
                activeDevice: nil,
                isPlaying: false
            )
        ]
        let viewModel = PlaybackSessionViewModel(playbackAPI: api, webCommander: MockWebPlaybackCommander())
        viewModel.handle(.ready(deviceID: "device-1"))
        viewModel.transportRateLimitedUntil = viewModel.clock.now.advanced(by: .seconds(-2))

        await viewModel.syncTransportFromSpotify()

        XCTAssertNil(viewModel.transportRateLimitedUntil)
    }

    private func sampleTrack(uri: String) -> PlaybackNowPlaying {
        PlaybackNowPlaying(
            name: "T",
            artists: ["A"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 100_000,
            positionMilliseconds: 0,
            uri: uri
        )
    }
}
