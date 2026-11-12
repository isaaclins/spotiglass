import XCTest
@testable import Spotiglass

@MainActor
final class PlaybackTransportSeekRepeatShuffleTests: XCTestCase {
    func testNextPreviousAndSeekUseWebAPIOnly() async {
        let commander = MockWebPlaybackCommander()
        let playbackAPI = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: playbackAPI, webCommander: commander),
            skipCommandMinimumSpacing: .zero
        )
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.next()
        await viewModel.previous()
        await viewModel.seek(to: 12_000)
        await viewModel.seekDispatchTask?.value

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

    func testSeeksQueuedBeforeTheFirstIsSentCoalesceToTheLatest() async {
        let api = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()),
            seekRateLimitInterval: .milliseconds(10),
            seekDeduplicationWindowMilliseconds: 0
        )
        viewModel.handle(.ready(deviceID: "device-1"))

        // `seek(to:)` only queues the intent and starts the dispatch task, which can't run
        // before this test suspends: all three seeks are queued before the first is sent.
        // A seek that arrives while another one is in flight isn't coalesced yet.
        await viewModel.seek(to: 10_000)
        await viewModel.seek(to: 20_000)
        await viewModel.seek(to: 30_000)
        XCTAssertTrue(api.seekCallTimestamps.isEmpty, "no seek should be sent before the test suspends")
        await viewModel.seekDispatchTask?.value

        let seeks = api.actions.filter { $0.hasPrefix("seek:") }
        XCTAssertEqual(seeks, ["seek:device-1:10000", "seek:device-1:30000"])
    }

    func testSeekRateLimitEnforcesMinimumSendSpacing() async {
        let api = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()),
            seekRateLimitInterval: .milliseconds(90),
            seekDeduplicationWindowMilliseconds: 0
        )
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.seek(to: 8_000)
        await viewModel.seek(to: 32_000)
        await viewModel.seekDispatchTask?.value

        XCTAssertEqual(api.seekCallTimestamps.count, 2)
        let spacing = api.seekCallTimestamps[1].timeIntervalSince(api.seekCallTimestamps[0])
        XCTAssertGreaterThanOrEqual(spacing, 0.08)
    }

    func testFailedSeekKeepsLateSameTrackStateFromClearingError() async {
        let api = MockPlaybackAPI()
        api.seekError = SpotifyAPIError.notFound(message: nil)
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()),
            seekRateLimitInterval: .milliseconds(10)
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        let track = PlaybackNowPlaying(
            name: "Track",
            artists: ["Artist"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 6_000,
            uri: "spotify:track:1"
        )
        viewModel.handle(.stateChanged(track, isPaused: false, nextTracks: []))

        await viewModel.seek(to: 92_000)
        await viewModel.seekDispatchTask?.value
        XCTAssertEqual(api.seekCallTimestamps.count, 1)
        XCTAssertNotNil(viewModel.connectionStateError)

        viewModel.handle(.stateChanged(track.with(positionMilliseconds: 7_000), isPaused: false, nextTracks: []))

        XCTAssertNotNil(viewModel.connectionStateError)
        XCTAssertNil(viewModel.currentNowPlaying)
    }

    func testFailedSeekKeepsErrorAfterURIlessStateTick() async {
        let api = MockPlaybackAPI()
        api.seekError = SpotifyAPIError.notFound(message: nil)
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()),
            seekRateLimitInterval: .zero
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        let track = PlaybackNowPlaying(
            name: "Track",
            artists: ["Artist"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 6_000,
            uri: "spotify:track:1"
        )
        viewModel.handle(.stateChanged(track, isPaused: false, nextTracks: []))
        await viewModel.seek(to: 92_000)
        await viewModel.seekDispatchTask?.value
        XCTAssertNotNil(viewModel.connectionStateError)

        viewModel.handle(.stateChanged(nil, isPaused: true, nextTracks: []))

        XCTAssertNotNil(viewModel.connectionStateError)
        XCTAssertNil(viewModel.currentNowPlaying)
    }

    func testFailedSeekClearsCoalescedIntentBeforePublishingError() async {
        let api = MockPlaybackAPI()
        api.seekError = SpotifyAPIError.notFound(message: nil)
        let firstSeekEntered = AsyncSignal()
        let releaseFirstSeek = AsyncSignal()
        api.onSeekAttempt = { milliseconds in
            if milliseconds == 92_000 {
                firstSeekEntered.signal()
                await releaseFirstSeek.wait()
            }
        }
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()),
            seekRateLimitInterval: .zero
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        let track = PlaybackNowPlaying(
            name: "Track",
            artists: ["Artist"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 6_000,
            uri: "spotify:track:1"
        )
        viewModel.handle(.stateChanged(track, isPaused: false, nextTracks: []))
        await viewModel.seek(to: 92_000)
        await firstSeekEntered.wait()
        await viewModel.seek(to: 93_000)
        releaseFirstSeek.signal()
        await viewModel.seekDispatchTask?.value

        XCTAssertNotNil(viewModel.connectionStateError)
        XCTAssertEqual(api.seekCallTimestamps.count, 1)
    }

    func testDifferentTrackStateRecoversAfterFailedSeekWithoutUsingFailedTarget() async {
        let api = MockPlaybackAPI()
        api.seekError = SpotifyAPIError.notFound(message: nil)
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()),
            seekRateLimitInterval: .zero
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        let trackA = PlaybackNowPlaying(
            name: "A",
            artists: ["Artist A"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 6_000,
            uri: "spotify:track:a"
        )
        let trackB = PlaybackNowPlaying(
            name: "B",
            artists: ["Artist B"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 0,
            uri: "spotify:track:b"
        )
        viewModel.handle(.stateChanged(trackA, isPaused: false, nextTracks: []))
        await viewModel.seek(to: 92_000)
        await viewModel.seekDispatchTask?.value

        viewModel.handle(.stateChanged(trackB, isPaused: false, nextTracks: []))

        guard case let .playing(nowPlaying) = viewModel.connectionState else {
            return XCTFail("Expected the different track to establish playback state")
        }
        XCTAssertEqual(nowPlaying.uri, trackB.uri)
        XCTAssertEqual(nowPlaying.positionMilliseconds, 0)
    }

    func testFirstSeekOnNewTrackIsNotDedupedAgainstPreviousTrack() async {
        let api = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()),
            seekRateLimitInterval: .zero
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        let trackA = PlaybackNowPlaying(
            name: "A",
            artists: ["Artist A"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 0,
            uri: "spotify:track:a"
        )
        let trackB = PlaybackNowPlaying(
            name: "B",
            artists: ["Artist B"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 0,
            uri: "spotify:track:b"
        )
        viewModel.handle(.stateChanged(trackA, isPaused: false, nextTracks: []))
        await viewModel.seek(to: 30_000)
        await viewModel.seekDispatchTask?.value

        viewModel.handle(.stateChanged(trackB, isPaused: false, nextTracks: []))
        await viewModel.seek(to: 30_100)
        await viewModel.seekDispatchTask?.value

        XCTAssertEqual(
            api.actions.filter { $0.hasPrefix("seek:") },
            ["seek:device-1:30000", "seek:device-1:30100"]
        )
    }

    func testTrackChangeDropsOldInFlightSeekAndDispatchesNewTrackIntent() async {
        let api = MockPlaybackAPI()
        let firstSeekEntered = AsyncSignal()
        let releaseFirstSeek = AsyncSignal()
        api.onSeekAttempt = { milliseconds in
            if milliseconds == 10_000 {
                firstSeekEntered.signal()
                await releaseFirstSeek.wait()
            }
        }
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()),
            seekRateLimitInterval: .zero,
            seekDeduplicationWindowMilliseconds: 0
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        let trackA = PlaybackNowPlaying(
            name: "A",
            artists: ["Artist A"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 6_000,
            uri: "spotify:track:a"
        )
        let trackB = PlaybackNowPlaying(
            name: "B",
            artists: ["Artist B"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 0,
            uri: "spotify:track:b"
        )
        viewModel.handle(.stateChanged(trackA, isPaused: false, nextTracks: []))
        await viewModel.seek(to: 10_000)
        await firstSeekEntered.wait()

        await viewModel.seek(to: 20_000)
        viewModel.handle(.stateChanged(trackB, isPaused: false, nextTracks: []))
        await viewModel.seek(to: 30_000)
        releaseFirstSeek.signal()
        await viewModel.seekDispatchTask?.value

        XCTAssertEqual(
            api.actions.filter { $0.hasPrefix("seek:") },
            ["seek:device-1:30000"]
        )
        guard case let .playing(nowPlaying) = viewModel.connectionState else {
            return XCTFail("Expected the new track to remain authoritative")
        }
        XCTAssertEqual(nowPlaying.uri, trackB.uri)
        XCTAssertEqual(nowPlaying.positionMilliseconds, 30_000)
    }

    func testNewHostLifecycleCancelsOldSeekBeforeDispatchingNewHostIntent() async {
        let api = MockPlaybackAPI()
        let firstSeekEntered = AsyncSignal()
        let releaseFirstSeek = AsyncSignal()
        api.onSeekAttempt = { milliseconds in
            if milliseconds == 10_000 {
                firstSeekEntered.signal()
                await releaseFirstSeek.wait()
            }
        }
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()),
            seekRateLimitInterval: .zero,
            seekDeduplicationWindowMilliseconds: 0
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        let trackA = PlaybackNowPlaying(
            name: "A",
            artists: ["Artist A"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 6_000,
            uri: "spotify:track:a"
        )
        let trackB = PlaybackNowPlaying(
            name: "B",
            artists: ["Artist B"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 0,
            uri: "spotify:track:b"
        )
        viewModel.handle(.stateChanged(trackA, isPaused: false, nextTracks: []))
        await viewModel.seek(to: 10_000)
        await firstSeekEntered.wait()

        let oldHostGeneration = viewModel.playbackHostGeneration
        let newHostGeneration = viewModel.beginPlaybackHostLifecycle()
        XCTAssertNotEqual(newHostGeneration, oldHostGeneration)
        viewModel.handle(.ready(deviceID: "device-2"))
        viewModel.handle(.stateChanged(trackB, isPaused: false, nextTracks: []))
        await viewModel.seek(to: 30_000)
        releaseFirstSeek.signal()
        await viewModel.seekDispatchTask?.value

        XCTAssertEqual(
            api.actions.filter { $0.hasPrefix("seek:") },
            ["seek:device-2:30000"]
        )
    }

    func testSeekSuppressionPreventsSnapBackUntilStateCatchesUp() async {
        let api = MockPlaybackAPI()
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()),
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

    func testTransportMutationsStayUnavailableUntilInitialSnapshotSucceeds() async {
        let api = MockPlaybackAPI()
        api.fetchPlayerSnapshotError = SpotifyAPIError.network("offline")
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()))
        viewModel.handle(.ready(deviceID: "device-1"))

        await viewModel.cycleRepeat()
        await viewModel.toggleShuffle()

        XCTAssertFalse(api.actions.contains { $0.hasPrefix("setRepeat:") })
        XCTAssertFalse(api.actions.contains { $0.hasPrefix("setShuffle:") })
    }

    func testCycleRepeatAdvancesRepeatMode() async {
        let api = MockPlaybackAPI()
        api.snapshotResponses = [MusicPlaybackSnapshot(
            transport: MusicPlaybackTransport(shuffle: false, repeatMode: .off),
            activeDevice: nil,
            isPlaying: false
        )]
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()),
            postRepeatSyncDelay: .milliseconds(50)
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        await viewModel.syncTransportFromSpotify()
        XCTAssertEqual(viewModel.repeatMode, .off)
        let fetchCountBeforeMutation = api.actions.filter { $0 == "fetchPlayerSnapshot" }.count

        await viewModel.cycleRepeat()
        await viewModel.repeatSyncTask?.value

        XCTAssertEqual(viewModel.repeatMode, .context)
        XCTAssertTrue(api.actions.contains("setRepeat:device-1:context"))
        XCTAssertGreaterThan(
            api.actions.filter { $0 == "fetchPlayerSnapshot" }.count,
            fetchCountBeforeMutation,
            "Background transport sync should run after repeat toggle."
        )
    }

    func testCycleRepeatFromContextTargetsTrack() async {
        let api = MockPlaybackAPI()
        api.snapshotResponses = [MusicPlaybackSnapshot(
            transport: MusicPlaybackTransport(shuffle: false, repeatMode: .context),
            activeDevice: nil,
            isPlaying: false
        )]
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()),
            postRepeatSyncDelay: .seconds(10)
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        await viewModel.syncTransportFromSpotify()

        await viewModel.cycleRepeat()

        XCTAssertEqual(viewModel.repeatMode, .track)
        XCTAssertTrue(api.actions.contains("setRepeat:device-1:track"))
    }

    func testCycleRepeatRevertsWhenSetRepeatFails() async {
        let api = MockPlaybackAPI()
        api.snapshotResponses = [MusicPlaybackSnapshot(
            transport: MusicPlaybackTransport(shuffle: false, repeatMode: .off),
            activeDevice: nil,
            isPlaying: false
        )]
        api.setRepeatError = SpotifyAPIError.notFound(message: nil)
        let viewModel = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()))
        viewModel.handle(.ready(deviceID: "device-1"))
        await viewModel.syncTransportFromSpotify()
        XCTAssertEqual(viewModel.repeatMode, .off)

        await viewModel.cycleRepeat()

        XCTAssertEqual(viewModel.repeatMode, .off)
        guard case .error = viewModel.connectionState else {
            return XCTFail("Expected error state after failed setRepeat")
        }
    }

    func testCycleRepeatFromTrackTargetsOff() async {
        let api = MockPlaybackAPI()
        api.snapshotResponses = [MusicPlaybackSnapshot(
            transport: MusicPlaybackTransport(shuffle: false, repeatMode: .track),
            activeDevice: nil,
            isPlaying: false
        )]
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()),
            postRepeatSyncDelay: .seconds(10)
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        await viewModel.syncTransportFromSpotify()

        await viewModel.cycleRepeat()

        XCTAssertEqual(viewModel.repeatMode, .off)
        XCTAssertTrue(api.actions.contains("setRepeat:device-1:off"))
    }

    func testRepeatSyncIgnoresStaleTransportWhilePending() async {
        let api = MockPlaybackAPI()
        api.transportResponses = [
            MusicPlaybackTransport(shuffle: false, repeatMode: .off)
        ]
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()),
            clock: ManualPlaybackClock(),
            pendingRepeatTimeout: .seconds(5),
            postRepeatSyncDelay: .seconds(10)
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        await viewModel.syncTransportFromSpotify()

        await viewModel.cycleRepeat()
        XCTAssertEqual(viewModel.repeatMode, .context)

        await viewModel.syncTransportFromSpotify()
        XCTAssertEqual(viewModel.repeatMode, .context, "Stale transport read should not overwrite optimistic repeat while pending.")
    }

    func testRepeatPendingClearsWhenTransportMatchesExpectedMode() async {
        let api = MockPlaybackAPI()
        api.transportResponses = [
            MusicPlaybackTransport(shuffle: false, repeatMode: .off),
            MusicPlaybackTransport(shuffle: false, repeatMode: .off),
            MusicPlaybackTransport(shuffle: false, repeatMode: .context),
            MusicPlaybackTransport(shuffle: false, repeatMode: .off)
        ]
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()),
            clock: ManualPlaybackClock(),
            pendingRepeatTimeout: .seconds(5),
            postRepeatSyncDelay: .seconds(10)
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        await viewModel.syncTransportFromSpotify()

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
            MusicPlaybackTransport(shuffle: false, repeatMode: .off),
            MusicPlaybackTransport(shuffle: false, repeatMode: .off)
        ]
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()),
            clock: ManualPlaybackClock(),
            pendingRepeatTimeout: .milliseconds(50),
            postRepeatSyncDelay: .seconds(10)
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        await viewModel.syncTransportFromSpotify()

        await viewModel.cycleRepeat()
        XCTAssertEqual(viewModel.repeatMode, .context)

        viewModel.pendingRepeatDeadline = viewModel.clock.now
        await viewModel.syncTransportFromSpotify()
        XCTAssertEqual(viewModel.repeatMode, .off, "After timeout, transport value should be accepted to avoid long-lived drift.")
    }

    func testCycleRepeatRapidTapsCoalesceWritesAndConvergeToLatestIntent() async {
        let api = MockPlaybackAPI()
        api.snapshotResponses = [MusicPlaybackSnapshot(
            transport: MusicPlaybackTransport(shuffle: false, repeatMode: .off),
            activeDevice: nil,
            isPlaying: false
        )]
        let firstWrite = MockCallHold()
        api.setRepeatHold = firstWrite
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()),
            repeatWriteMinInterval: .milliseconds(40),
            postRepeatSyncDelay: .seconds(10)
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        await viewModel.syncTransportFromSpotify()

        let tap1 = Task { await viewModel.cycleRepeat() } // off -> context
        let didSendFirstWrite = await firstWrite.entered.wait(timeout: .seconds(mustHappenTimeout))
        XCTAssertTrue(didSendFirstWrite, "the first repeat write should be in flight before the next taps")
        guard await finishes("the next repeat taps waited for the first write instead of returning", elseRelease: firstWrite.release, {
            await viewModel.cycleRepeat() // context -> track
            await viewModel.cycleRepeat() // track -> off
        }) else { return }
        firstWrite.release()
        await tap1.value

        let repeatWrites = api.actions.filter { $0.hasPrefix("setRepeat:") }
        XCTAssertEqual(repeatWrites.count, 2, "Rapid repeat taps should coalesce to at most first+latest writes.")
        XCTAssertEqual(repeatWrites.first, "setRepeat:device-1:context")
        XCTAssertEqual(repeatWrites.last, "setRepeat:device-1:off")
        XCTAssertEqual(viewModel.repeatMode, .off, "Final visible repeat mode should match latest user intent.")
    }

    func testCycleRepeatRapidTapsAvoidSendingIntermediateModes() async {
        let api = MockPlaybackAPI()
        api.snapshotResponses = [MusicPlaybackSnapshot(
            transport: MusicPlaybackTransport(shuffle: false, repeatMode: .off),
            activeDevice: nil,
            isPlaying: false
        )]
        let firstWrite = MockCallHold()
        api.setRepeatHold = firstWrite
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()),
            repeatWriteMinInterval: .milliseconds(40),
            postRepeatSyncDelay: .seconds(10)
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        await viewModel.syncTransportFromSpotify()

        let tap1 = Task { await viewModel.cycleRepeat() } // off -> context
        let didSendFirstWrite = await firstWrite.entered.wait(timeout: .seconds(mustHappenTimeout))
        XCTAssertTrue(didSendFirstWrite, "the first repeat write should be in flight before the second tap")
        guard await finishes("the second repeat tap waited for the first write instead of returning", elseRelease: firstWrite.release, {
            await viewModel.cycleRepeat() // context -> track
        }) else { return }
        firstWrite.release()
        await tap1.value

        let repeatWrites = api.actions.filter { $0.hasPrefix("setRepeat:") }
        XCTAssertEqual(repeatWrites.count, 2)
        XCTAssertEqual(repeatWrites, [
            "setRepeat:device-1:context",
            "setRepeat:device-1:track"
        ])
    }

    func testToggleShuffleFlipsShuffleEnabled() async {
        let api = MockPlaybackAPI()
        api.snapshotResponses = [MusicPlaybackSnapshot(
            transport: MusicPlaybackTransport(shuffle: false, repeatMode: .off),
            activeDevice: nil,
            isPlaying: false
        )]
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()),
            postShuffleSyncDelay: .milliseconds(20)
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        await viewModel.syncTransportFromSpotify()
        XCTAssertFalse(viewModel.shuffleEnabled)
        let fetchCountBeforeMutation = api.actions.filter { $0 == "fetchPlayerSnapshot" }.count

        await viewModel.toggleShuffle()
        await viewModel.shuffleSyncTask?.value

        XCTAssertTrue(viewModel.shuffleEnabled)
        XCTAssertTrue(api.actions.contains("setShuffle:device-1:true"))
        XCTAssertGreaterThan(
            api.actions.filter { $0 == "fetchPlayerSnapshot" }.count,
            fetchCountBeforeMutation
        )
    }

    func testToggleShuffleFromEnabledTargetsDisabled() async {
        let api = MockPlaybackAPI()
        api.snapshotResponses = [MusicPlaybackSnapshot(
            transport: MusicPlaybackTransport(shuffle: true, repeatMode: .off),
            activeDevice: nil,
            isPlaying: false
        )]
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()),
            postShuffleSyncDelay: .seconds(10)
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        await viewModel.syncTransportFromSpotify()

        await viewModel.toggleShuffle()

        XCTAssertFalse(viewModel.shuffleEnabled)
        XCTAssertTrue(api.actions.contains("setShuffle:device-1:false"))
    }

    func testToggleShuffleRevertsWhenSetShuffleFails() async {
        let api = MockPlaybackAPI()
        api.snapshotResponses = [MusicPlaybackSnapshot(
            transport: MusicPlaybackTransport(shuffle: false, repeatMode: .off),
            activeDevice: nil,
            isPlaying: false
        )]
        api.setShuffleError = SpotifyAPIError.notFound(message: nil)
        let viewModel = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()))
        viewModel.handle(.ready(deviceID: "device-1"))
        await viewModel.syncTransportFromSpotify()

        await viewModel.toggleShuffle()

        XCTAssertFalse(viewModel.shuffleEnabled)
        guard case .error = viewModel.connectionState else {
            return XCTFail("Expected error state after failed setShuffle")
        }
    }

    func testShuffleSyncIgnoresStaleTransportWhilePending() async {
        let api = MockPlaybackAPI()
        api.transportResponses = [MusicPlaybackTransport(shuffle: false, repeatMode: .off)]
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()),
            clock: ManualPlaybackClock(),
            pendingShuffleTimeout: .seconds(5),
            postShuffleSyncDelay: .seconds(10)
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        await viewModel.syncTransportFromSpotify()

        await viewModel.toggleShuffle()
        XCTAssertTrue(viewModel.shuffleEnabled)

        await viewModel.syncTransportFromSpotify()
        XCTAssertTrue(viewModel.shuffleEnabled, "Stale shuffle transport read should not overwrite optimistic local state while pending.")
    }

    func testShufflePendingClearsWhenTransportMatchesExpectedState() async {
        let api = MockPlaybackAPI()
        api.transportResponses = [
            MusicPlaybackTransport(shuffle: false, repeatMode: .off),
            MusicPlaybackTransport(shuffle: false, repeatMode: .off),
            MusicPlaybackTransport(shuffle: true, repeatMode: .off),
            MusicPlaybackTransport(shuffle: false, repeatMode: .off)
        ]
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()),
            clock: ManualPlaybackClock(),
            pendingShuffleTimeout: .seconds(5),
            postShuffleSyncDelay: .seconds(10)
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        await viewModel.syncTransportFromSpotify()

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
        api.transportResponses = [
            MusicPlaybackTransport(shuffle: false, repeatMode: .off),
            MusicPlaybackTransport(shuffle: false, repeatMode: .off)
        ]
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()),
            clock: ManualPlaybackClock(),
            pendingShuffleTimeout: .milliseconds(50),
            postShuffleSyncDelay: .seconds(10)
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        await viewModel.syncTransportFromSpotify()

        await viewModel.toggleShuffle()
        XCTAssertTrue(viewModel.shuffleEnabled)

        viewModel.pendingShuffleDeadline = viewModel.clock.now
        await viewModel.syncTransportFromSpotify()
        XCTAssertFalse(viewModel.shuffleEnabled, "After timeout, transport shuffle should be accepted to avoid drift.")
    }

    func testRapidShuffleTogglesCoalesceInFlightWrites() async {
        let api = MockPlaybackAPI()
        api.snapshotResponses = [MusicPlaybackSnapshot(
            transport: MusicPlaybackTransport(shuffle: false, repeatMode: .off),
            activeDevice: nil,
            isPlaying: false
        )]
        let firstWrite = MockCallHold()
        api.setShuffleHold = firstWrite
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()),
            postShuffleSyncDelay: .seconds(10)
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        await viewModel.syncTransportFromSpotify()
        XCTAssertFalse(viewModel.shuffleEnabled)

        let firstToggle = Task { await viewModel.toggleShuffle() }
        let didSendFirstWrite = await firstWrite.entered.wait(timeout: .seconds(mustHappenTimeout))
        XCTAssertTrue(
            didSendFirstWrite,
            "the first shuffle write should be in flight before the second toggle"
        )
        guard await finishes("the second shuffle toggle waited for the first write instead of returning", elseRelease: firstWrite.release, {
            await viewModel.toggleShuffle()
        }) else { return }
        firstWrite.release()
        await firstToggle.value

        let shuffleWrites = api.actions.filter { $0.hasPrefix("setShuffle:") }
        XCTAssertEqual(shuffleWrites, ["setShuffle:device-1:true", "setShuffle:device-1:false"])
        XCTAssertFalse(viewModel.shuffleEnabled)
    }

    func testOlderShuffleSyncDoesNotOverrideNewerMutation() async {
        let api = MockPlaybackAPI()
        api.snapshotResponses = [MusicPlaybackSnapshot(
            transport: MusicPlaybackTransport(shuffle: false, repeatMode: .off),
            activeDevice: nil,
            isPlaying: false
        )]
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()),
            postShuffleSyncDelay: .seconds(10)
        )
        viewModel.handle(.ready(deviceID: "device-1"))
        await viewModel.syncTransportFromSpotify()

        await viewModel.toggleShuffle()
        XCTAssertTrue(viewModel.shuffleEnabled)

        // This simulates a delayed sync response from an older mutation; it
        // should be ignored instead of regressing the newer local target.
        api.transportResponses = [MusicPlaybackTransport(shuffle: false, repeatMode: .off)]
        await viewModel.syncTransportFromSpotify(minimumShuffleMutationVersion: 0)
        XCTAssertTrue(viewModel.shuffleEnabled)
    }

}
