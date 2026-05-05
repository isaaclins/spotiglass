import XCTest
@testable import Spotiglass

@MainActor
final class QueuePanelTests: XCTestCase {
    func testQueueItemArtistTapTargetsPreferArtistRefs() {
        let track = SpotifyTrack(
            id: "track-1",
            name: "Track",
            artists: ["Shown Name"],
            artistRefs: [SpotifyArtistRef(id: "artist-1", name: "Resolved Artist")],
            albumArtworkURL: nil,
            durationMilliseconds: 180_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "spotify:track:track-1"
        )

        let item = QueueItem.from(track: track, source: .upcoming)
        XCTAssertEqual(item.artistTapTargets, [ArtistTapTarget(id: "artist-1", name: "Resolved Artist")])
    }

    func testBridgeParsesNextTracksArray() throws {
        let event = try SpotifyPlaybackBridgeParser.parse([
            "name": "state_changed",
            "payload": [
                "paused": false,
                "nextTracks": [
                    [
                        "name": "Next Track",
                        "artists": ["Artist"],
                        "albumArtURL": "https://example.com/a.png",
                        "durationMilliseconds": 200_000,
                        "positionMilliseconds": 0,
                        "uri": "spotify:track:next"
                    ]
                ],
                "track": [
                    "name": "Current",
                    "artists": ["Artist"],
                    "durationMilliseconds": 180_000,
                    "positionMilliseconds": 0,
                    "uri": "spotify:track:current"
                ]
            ]
        ])

        guard case let .stateChanged(nowPlaying, isPaused, nextTracks) = event else {
            return XCTFail("Expected state changed")
        }
        XCTAssertFalse(isPaused)
        XCTAssertEqual(nowPlaying?.uri, "spotify:track:current")
        XCTAssertEqual(nextTracks.count, 1)
        XCTAssertEqual(nextTracks.first?.name, "Next Track")
        XCTAssertEqual(nextTracks.first?.uri, "spotify:track:next")
    }

    func testQueueViewModelMergesSDKTracksWithAPIQueueSources() async {
        let api = QueueTestPlaybackAPI()
        let commander = StubWebPlaybackCommander()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: commander)
        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback, pollIntervalNanoseconds: 60_000_000_000)

        playback.handle(.ready(deviceID: "device-1"))
        let sdkNext = [
            PlaybackNowPlaying(name: "A", artists: ["a"], albumName: nil, albumArtURL: nil, durationMilliseconds: 100_000, positionMilliseconds: 0, uri: "spotify:track:a"),
            PlaybackNowPlaying(name: "B", artists: ["b"], albumName: nil, albumArtURL: nil, durationMilliseconds: 100_000, positionMilliseconds: 0, uri: "spotify:track:b")
        ]
        playback.handle(.stateChanged(
            PlaybackNowPlaying(name: "Cur", artists: ["c"], albumName: nil, albumArtURL: nil, durationMilliseconds: 120_000, positionMilliseconds: 0, uri: "spotify:track:cur"),
            isPaused: false,
            nextTracks: sdkNext
        ))

        let trackA = SpotifyTrack(id: "a", name: "A", artists: ["a"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:a")
        let trackB = SpotifyTrack(id: "b", name: "B", artists: ["b"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:b")
        let trackC = SpotifyTrack(id: "c", name: "C", artists: ["c"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:c")

        api.queueResponse = SpotifyQueueResponse(
            currentlyPlaying: nil,
            queue: [.track(trackA), .track(trackB), .track(trackC)]
        )

        queue.setPanelVisible(true)
        await queue.refreshQueue()

        XCTAssertEqual(queue.upcomingItems.count, 3)
        XCTAssertEqual(queue.upcomingItems[0].source, .sdk)
        XCTAssertEqual(queue.upcomingItems[1].source, .sdk)
        XCTAssertEqual(queue.upcomingItems[2].source, .userQueued)
    }

    func testQueueViewModelSkipsFetchWhenPanelHidden() async {
        let api = QueueTestPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: StubWebPlaybackCommander())
        playback.handle(.ready(deviceID: "device-1"))
        playback.handle(.stateChanged(
            PlaybackNowPlaying(name: "T", artists: [], albumName: nil, albumArtURL: nil, durationMilliseconds: 60_000, positionMilliseconds: 0, uri: "spotify:track:t"),
            isPaused: false,
            nextTracks: []
        ))

        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback, pollIntervalNanoseconds: 50_000_000)
        queue.setPanelVisible(false)
        await queue.refreshQueue()

        XCTAssertFalse(api.actions.contains("fetchQueue"))
    }

    func testQueueViewModelAddToQueueUsesDeviceIDAndRefetches() async {
        let api = QueueTestPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: StubWebPlaybackCommander())
        playback.handle(.ready(deviceID: "device-42"))

        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback)
        queue.setPanelVisible(true)

        await queue.addToQueue(uri: "spotify:track:add-me")

        XCTAssertTrue(api.actions.contains("addToQueue:device-42:spotify:track:add-me"))
        XCTAssertTrue(api.actions.filter { $0 == "fetchQueue" }.count >= 1)
    }

    func testQueueViewModelDoesNotShowErrorBannerForCancellation() async {
        let api = QueueTestPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: StubWebPlaybackCommander())
        playback.handle(.ready(deviceID: "device-1"))

        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback)
        queue.setPanelVisible(true)

        api.errorToThrow = CancellationError()
        await queue.refreshQueue()
        XCTAssertNil(queue.lastError, "CancellationError must not surface as a user-visible queue banner.")

        api.errorToThrow = URLError(.cancelled)
        await queue.refreshQueue()
        XCTAssertNil(queue.lastError, "URLError.cancelled must not surface as a user-visible queue banner.")
    }

    func testQueueSkipAdvanceUsesImmediateSDKProjectionWithoutNowPlayingDuplication() async {
        let api = QueueTestPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: StubWebPlaybackCommander())
        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback, pollIntervalNanoseconds: 60_000_000_000)
        playback.handle(.ready(deviceID: "device-1"))

        let oldNow = PlaybackNowPlaying(
            name: "Old",
            artists: ["A"],
            albumName: nil,
            albumArtURL: nil,
            durationMilliseconds: 100_000,
            positionMilliseconds: 0,
            uri: "spotify:track:old"
        )
        playback.handle(.stateChanged(oldNow, isPaused: false, nextTracks: [
            PlaybackNowPlaying(name: "Next", artists: ["B"], albumName: nil, albumArtURL: nil, durationMilliseconds: 100_000, positionMilliseconds: 0, uri: "spotify:track:next")
        ]))

        let oldTrack = SpotifyTrack(id: "old", name: "Old", artists: ["A"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:old")
        let nextTrack = SpotifyTrack(id: "next", name: "Next", artists: ["B"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:next")
        let thirdTrack = SpotifyTrack(id: "third", name: "Third", artists: ["C"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:third")
        api.queueResponse = SpotifyQueueResponse(currentlyPlaying: .track(oldTrack), queue: [.track(nextTrack), .track(thirdTrack)])

        queue.setPanelVisible(true)
        await queue.refreshQueue()

        let newNow = PlaybackNowPlaying(
            name: "Next",
            artists: ["B"],
            albumName: nil,
            albumArtURL: nil,
            durationMilliseconds: 100_000,
            positionMilliseconds: 0,
            uri: "spotify:track:next"
        )
        playback.handle(.stateChanged(newNow, isPaused: false, nextTracks: [
            PlaybackNowPlaying(name: "Third", artists: ["C"], albumName: nil, albumArtURL: nil, durationMilliseconds: 100_000, positionMilliseconds: 0, uri: "spotify:track:third")
        ]))

        queue.handlePlaybackStateChange()

        XCTAssertEqual(queue.nowPlayingItem?.uri, "spotify:track:next")
        XCTAssertEqual(queue.upcomingItems.first?.uri, "spotify:track:third")
        XCTAssertFalse(queue.upcomingItems.contains(where: { $0.uri == "spotify:track:next" }))
    }

    func testQueueShuffleAppliesOptimisticOrderBeforeReconciliation() async {
        let api = QueueTestPlaybackAPI()
        api.fetchQueueDelayNanoseconds = 200_000_000
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: StubWebPlaybackCommander(), postShuffleSyncDelay: .seconds(10))
        playback.handle(.ready(deviceID: "device-1"))
        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback, pollIntervalNanoseconds: 60_000_000_000)

        let one = SpotifyTrack(id: "1", name: "One", artists: ["A"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:1")
        let two = SpotifyTrack(id: "2", name: "Two", artists: ["B"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:2")
        let three = SpotifyTrack(id: "3", name: "Three", artists: ["C"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:3")
        api.queueResponse = SpotifyQueueResponse(currentlyPlaying: nil, queue: [.track(one), .track(two), .track(three)])
        queue.setPanelVisible(true)
        await queue.refreshQueue()
        let original = queue.upcomingItems.map(\.id)
        XCTAssertGreaterThan(original.count, 1, "Test requires multiple upcoming items.")

        let toggleTask = Task { await queue.toggleShuffle() }
        var sawOptimisticReorder = false
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if queue.upcomingItems.map(\.id) != original {
                sawOptimisticReorder = true
                break
            }
        }
        XCTAssertTrue(sawOptimisticReorder, "Queue should reorder before slow Spotify reconciliation finishes.")
        await toggleTask.value
    }

    func testQueueShuffleOffRestoresPreShuffleSnapshotImmediately() async {
        let api = QueueTestPlaybackAPI()
        api.fetchQueueDelayNanoseconds = 180_000_000
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: StubWebPlaybackCommander(), postShuffleSyncDelay: .seconds(10))
        playback.handle(.ready(deviceID: "device-1"))
        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback, pollIntervalNanoseconds: 60_000_000_000)

        let one = SpotifyTrack(id: "1", name: "One", artists: ["A"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:1")
        let two = SpotifyTrack(id: "2", name: "Two", artists: ["B"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:2")
        let three = SpotifyTrack(id: "3", name: "Three", artists: ["C"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:3")
        api.queueResponse = SpotifyQueueResponse(currentlyPlaying: nil, queue: [.track(one), .track(two), .track(three)])
        queue.setPanelVisible(true)
        await queue.refreshQueue()
        let original = queue.upcomingItems.map(\.id)
        XCTAssertGreaterThan(original.count, 1, "Test requires multiple upcoming items.")
        api.errorToThrow = CancellationError()

        await queue.toggleShuffle()

        let offTask = Task { await queue.toggleShuffle() }
        var sawRestoredSnapshot = false
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if queue.upcomingItems.map(\.id) == original {
                sawRestoredSnapshot = true
                break
            }
        }
        XCTAssertTrue(sawRestoredSnapshot, "Turning shuffle off should restore pre-shuffle ordering before reconciliation finishes.")
        await offTask.value
    }

    func testQueueShuffleFailureRestoresPreviousOrdering() async {
        let api = QueueTestPlaybackAPI()
        api.setShuffleError = SpotifyAPIError.notFound(message: nil)
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: StubWebPlaybackCommander(), postShuffleSyncDelay: .seconds(10))
        playback.handle(.ready(deviceID: "device-1"))
        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback, pollIntervalNanoseconds: 60_000_000_000)

        let one = SpotifyTrack(id: "1", name: "One", artists: ["A"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:1")
        let two = SpotifyTrack(id: "2", name: "Two", artists: ["B"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:2")
        api.queueResponse = SpotifyQueueResponse(currentlyPlaying: nil, queue: [.track(one), .track(two)])
        queue.setPanelVisible(true)
        await queue.refreshQueue()
        let original = queue.upcomingItems.map(\.id)

        await queue.toggleShuffle()

        XCTAssertEqual(queue.upcomingItems.map(\.id), original)
        XCTAssertFalse(playback.shuffleEnabled)
    }

    func testQueueShuffleDoesNotSnapBackOnFirstStaleReconciliationFetch() async {
        let api = QueueTestPlaybackAPI()
        api.fetchQueueDelayNanoseconds = 50_000_000
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: StubWebPlaybackCommander(), postShuffleSyncDelay: .seconds(10))
        playback.handle(.ready(deviceID: "device-1"))
        let queue = QueueViewModel(
            playbackAPI: api,
            playbackSession: playback,
            pollIntervalNanoseconds: 60_000_000_000,
            optimisticReconcileTimeout: .seconds(5)
        )

        let one = SpotifyTrack(id: "1", name: "One", artists: ["A"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:1")
        let two = SpotifyTrack(id: "2", name: "Two", artists: ["B"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:2")
        let three = SpotifyTrack(id: "3", name: "Three", artists: ["C"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:3")
        let originalQueue = SpotifyQueueResponse(currentlyPlaying: nil, queue: [.track(one), .track(two), .track(three)])
        let shuffledQueue = SpotifyQueueResponse(currentlyPlaying: nil, queue: [.track(three), .track(one), .track(two)])
        api.queueResponses = [originalQueue, originalQueue, originalQueue, shuffledQueue, shuffledQueue]
        queue.setPanelVisible(true)
        await queue.refreshQueue()
        let original = queue.upcomingItems.map(\.id)
        XCTAssertEqual(original.count, 3)

        await queue.toggleShuffle()
        let afterToggle = queue.upcomingItems.map(\.id)
        XCTAssertNotEqual(afterToggle, original, "Optimistic shuffle should be visible immediately.")
        let optimistic = afterToggle

        // First reconciliation fetch is stale (server still old order).
        await queue.refreshQueue()
        XCTAssertEqual(
            queue.upcomingItems.map(\.id),
            optimistic,
            "Queue must keep optimistic order instead of snapping back to stale server order."
        )

        // Second reconciliation fetch confirms shuffled server state.
        await queue.refreshQueue()
        XCTAssertNotEqual(
            queue.upcomingItems.map(\.id),
            original,
            "Confirmed reconciliation should remain off the original non-shuffled ordering."
        )
    }
}

private final class StubWebPlaybackCommander: WebPlaybackCommanding {
    func loadHost() {}

    func send(_ command: PlaybackBridgeCommand, payload: [String: Any]) async throws {}
}

private final class QueueTestPlaybackAPI: SpotifyPlaybackControlling {
    private(set) var actions: [String] = []
    var queueResponse = SpotifyQueueResponse(currentlyPlaying: nil, queue: [])
    var errorToThrow: Error?
    var setShuffleError: Error?
    var setRepeatError: Error?
    var fetchQueueDelayNanoseconds: UInt64 = 0
    var queueResponses: [SpotifyQueueResponse] = []
    private var reportedTransport = SpotifyPlayerTransport(shuffle: false, repeatMode: .off)

    func transferPlayback(to deviceID: String, play: Bool) async throws {
        actions.append("transfer:\(deviceID):\(play)")
    }

    func play(uri: String, deviceID: String) async throws {
        actions.append("play:\(deviceID):\(uri)")
    }

    func play(contextURI: String, deviceID: String) async throws {
        actions.append("play-context:\(deviceID):\(contextURI)")
    }

    func play(uris: [String], deviceID: String) async throws {
        actions.append("play-list:\(deviceID):\(uris.joined(separator: ","))")
    }

    func pause(deviceID: String) async throws {}

    func resume(deviceID: String) async throws {}

    func seek(to milliseconds: Int, deviceID: String) async throws {}

    func next(deviceID: String) async throws {}

    func previous(deviceID: String) async throws {}

    func fetchQueue() async throws -> SpotifyQueueResponse {
        actions.append("fetchQueue")
        if fetchQueueDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: fetchQueueDelayNanoseconds)
        }
        if let errorToThrow {
            throw errorToThrow
        }
        if !queueResponses.isEmpty {
            return queueResponses.removeFirst()
        }
        return queueResponse
    }

    func addToQueue(uri: String, deviceID: String) async throws {
        actions.append("addToQueue:\(deviceID):\(uri)")
    }

    func fetchPlayerTransport() async throws -> SpotifyPlayerTransport? {
        actions.append("fetchPlayerTransport")
        return reportedTransport
    }

    func setShuffle(enabled: Bool, deviceID: String) async throws {
        if let setShuffleError { throw setShuffleError }
        actions.append("setShuffle:\(deviceID):\(enabled)")
        reportedTransport = SpotifyPlayerTransport(shuffle: enabled, repeatMode: reportedTransport.repeatMode)
    }

    func setRepeat(mode: SpotifyRepeatMode, deviceID: String) async throws {
        if let setRepeatError { throw setRepeatError }
        actions.append("setRepeat:\(deviceID):\(mode.rawValue)")
        reportedTransport = SpotifyPlayerTransport(shuffle: reportedTransport.shuffle, repeatMode: mode)
    }
}
