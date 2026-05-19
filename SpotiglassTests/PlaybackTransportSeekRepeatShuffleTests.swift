import XCTest
@testable import Spotiglass

@MainActor
final class PlaybackTransportSeekRepeatShuffleTests: XCTestCase {
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
        let seekDeadline = Date().addingTimeInterval(1.5)
        while Date() < seekDeadline {
            let seeks = api.actions.filter { $0.hasPrefix("seek:") }
            if seeks == ["seek:device-1:10000", "seek:device-1:30000"] { return }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
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
        let seekDeadline = Date().addingTimeInterval(1.5)
        while Date() < seekDeadline, api.seekCallTimestamps.count < 2 {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }

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
            postRepeatSyncDelay: .milliseconds(50)
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        XCTAssertEqual(viewModel.repeatMode, .off)

        await viewModel.cycleRepeat()

        XCTAssertEqual(viewModel.repeatMode, .context)
        XCTAssertTrue(api.actions.contains("setRepeat:device-1:context"))
        let syncDeadline = Date().addingTimeInterval(1.0)
        while Date() < syncDeadline, !api.actions.contains("fetchPlayerSnapshot") {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
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

}
