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

        let item = QueueItem.from(track: track)
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

    func testQueueDisconnectClearsFetchedQueueProjectionImmediately() async {
        let api = QueueTestPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: StubWebPlaybackCommander())
        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback, pollIntervalNanoseconds: 60_000_000_000)

        playback.handle(.ready(deviceID: "device-1"))
        let current = PlaybackNowPlaying(
            name: "Current",
            artists: ["Artist"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 120_000,
            positionMilliseconds: 0,
            uri: "spotify:track:current"
        )
        playback.handle(.stateChanged(current, isPaused: false, nextTracks: []))
        let next = SpotifyTrack(
            id: "next",
            name: "Next",
            artists: ["Artist"],
            albumArtworkURL: nil,
            durationMilliseconds: 100_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "spotify:track:next"
        )
        api.queueResponse = SpotifyQueueResponse(queue: [.track(next)])

        queue.setPanelVisible(true)
        await queue.refreshQueue()
        XCTAssertEqual(queue.nowPlayingItem?.uri, current.uri)
        XCTAssertEqual(queue.upcomingItems.map(\.uri), [next.uri])

        await playback.disconnect()
        queue.handlePlaybackStateChange()

        XCTAssertNil(queue.nowPlayingItem)
        XCTAssertTrue(queue.upcomingItems.isEmpty)
        XCTAssertNil(queue.lastFetchedQueue)
    }

    func testQueueUnavailableClearsRESTAndOptimisticProjectionImmediately() {
        let api = QueueTestPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: StubWebPlaybackCommander())
        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback)
        let current = PlaybackNowPlaying(
            name: "Current",
            artists: ["Artist"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 120_000,
            positionMilliseconds: 0,
            uri: "spotify:track:current"
        )
        playback.handle(.ready(deviceID: "device-1"))
        playback.handle(.stateChanged(current, isPaused: false, nextTracks: []))
        let cached = QueueItem(
            name: "Cached",
            subtitle: "Artist",
            albumArtURL: nil,
            durationMilliseconds: 100_000,
            uri: "spotify:track:cached"
        )
        queue.lastFetchedQueue = SpotifyQueueResponse(queue: [])
        queue.optimisticUpcomingItems = [cached]
        queue.preShuffleUpcomingSnapshot = [cached]
        queue.publishMergedState()
        queue.upcomingItems = [cached]

        playback.setConnectionState(.unavailable("device lost"))
        queue.handlePlaybackStateChange()

        XCTAssertNil(queue.nowPlayingItem)
        XCTAssertTrue(queue.upcomingItems.isEmpty)
        XCTAssertNil(queue.lastFetchedQueue)
        XCTAssertNil(queue.optimisticUpcomingItems)
        XCTAssertNil(queue.preShuffleUpcomingSnapshot)
    }

    func testQueueDiscardStaleFetchAfterDisconnectBeforeReconnect() async {
        let api = QueueTestPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: StubWebPlaybackCommander())
        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback, pollIntervalNanoseconds: 60_000_000_000)

        playback.handle(.ready(deviceID: "device-1"))
        let oldCurrent = PlaybackNowPlaying(
            name: "Old current",
            artists: ["Artist"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 120_000,
            positionMilliseconds: 0,
            uri: "spotify:track:old-current"
        )
        playback.handle(.stateChanged(oldCurrent, isPaused: false, nextTracks: []))
        let oldNext = SpotifyTrack(
            id: "old-next",
            name: "Old next",
            artists: ["Artist"],
            albumArtworkURL: nil,
            durationMilliseconds: 100_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "spotify:track:old-next"
        )
        api.queueResponse = SpotifyQueueResponse(queue: [.track(oldNext)])
        queue.lastFetchedQueue = api.queueResponse
        queue.publishMergedState()
        queue.isPanelVisible = true

        api.fetchQueueDelayNanoseconds = 150_000_000
        let refreshTask = Task { await queue.refreshQueue() }
        let fetchStarted = await api.fetchQueueSignal.wait(timeout: .seconds(1))
        XCTAssertTrue(fetchStarted)
        queue.isPanelVisible = false

        await playback.disconnect()
        queue.handlePlaybackStateChange()
        playback.handle(.ready(deviceID: "device-2"))
        playback.handle(.stateChanged(
            PlaybackNowPlaying(
                name: "New current",
                artists: ["Artist"],
                albumName: nil,
                albumID: nil,
                albumArtURL: nil,
                durationMilliseconds: 120_000,
                positionMilliseconds: 0,
                uri: "spotify:track:new-current"
            ),
            isPaused: false,
            nextTracks: []
        ))
        queue.handlePlaybackStateChange()

        await refreshTask.value

        XCTAssertNil(queue.lastFetchedQueue)
        XCTAssertFalse(queue.upcomingItems.contains(where: { $0.uri == oldNext.uri }))
    }

    func testQueueIgnoresStaleFetchErrorAfterDisconnectBeforeReconnect() async {
        let api = QueueTestPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: StubWebPlaybackCommander())
        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback, pollIntervalNanoseconds: 60_000_000_000)

        playback.handle(.ready(deviceID: "device-1"))
        playback.handle(.stateChanged(
            PlaybackNowPlaying(
                name: "Current",
                artists: ["Artist"],
                albumName: nil,
                albumID: nil,
                albumArtURL: nil,
                durationMilliseconds: 120_000,
                positionMilliseconds: 0,
                uri: "spotify:track:current"
            ),
            isPaused: false,
            nextTracks: []
        ))
        queue.isPanelVisible = true
        api.fetchQueueDelayNanoseconds = 150_000_000
        api.errorToThrow = SpotifyAPIError.unauthorized

        let refreshTask = Task { await queue.refreshQueue() }
        let fetchStarted = await api.fetchQueueSignal.wait(timeout: .seconds(1))
        XCTAssertTrue(fetchStarted)
        queue.isPanelVisible = false

        await playback.disconnect()
        queue.handlePlaybackStateChange()
        playback.handle(.ready(deviceID: "device-2"))
        queue.handlePlaybackStateChange()

        await refreshTask.value

        XCTAssertNil(queue.lastError)
    }

    func testSDKProjectionRetainsCurrentURIAndDuplicateOccurrences() {
        let api = QueueTestPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: StubWebPlaybackCommander())
        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback)
        let currentURI = "spotify:track:current"
        let current = PlaybackNowPlaying(
            name: "Current",
            artists: ["Artist"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 120_000,
            positionMilliseconds: 0,
            uri: currentURI
        )

        playback.handle(.ready(deviceID: "device-1"))
        playback.handle(.stateChanged(current, isPaused: false, nextTracks: [current]))
        queue.syncFromPlaybackSession()
        XCTAssertEqual(queue.upcomingItems.map(\.uri), [currentURI])

        playback.handle(.stateChanged(current, isPaused: false, nextTracks: [current, current]))
        queue.syncFromPlaybackSession()

        XCTAssertEqual(queue.upcomingItems.map(\.uri), [currentURI, currentURI])
        XCTAssertEqual(Set(queue.upcomingItems.map(\.id)).count, queue.upcomingItems.count)
    }

    func testQueueProjectionPreservesCurrentURIOccurrencesWithStableUniqueIDs() async {
        let api = QueueTestPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: StubWebPlaybackCommander())
        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback, pollIntervalNanoseconds: 60_000_000_000)

        playback.handle(.ready(deviceID: "device-1"))
        let current = PlaybackNowPlaying(
            name: "Current",
            artists: ["Artist"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 120_000,
            positionMilliseconds: 0,
            uri: "spotify:track:current"
        )
        playback.handle(.stateChanged(current, isPaused: false, nextTracks: []))
        let currentTrack = SpotifyTrack(
            id: "current",
            name: "Current",
            artists: ["Artist"],
            albumArtworkURL: nil,
            durationMilliseconds: 120_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "spotify:track:current"
        )
        let duplicateTrack = SpotifyTrack(
            id: "current-duplicate",
            name: "Current duplicate",
            artists: ["Artist"],
            albumArtworkURL: nil,
            durationMilliseconds: 120_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "spotify:track:current"
        )
        let nextTrack = SpotifyTrack(
            id: "next",
            name: "Next",
            artists: ["Next Artist"],
            albumArtworkURL: nil,
            durationMilliseconds: 100_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "spotify:track:next"
        )
        api.queueResponse = SpotifyQueueResponse(
            queue: [.track(currentTrack), .track(duplicateTrack), .track(nextTrack)]
        )

        queue.setPanelVisible(true)
        await queue.refreshQueue()
        let firstIDs = queue.upcomingItems.map(\.id)

        await queue.refreshQueue()

        XCTAssertEqual(queue.upcomingItems.map(\.uri), [current.uri, current.uri, nextTrack.uri])
        XCTAssertEqual(Set(firstIDs).count, firstIDs.count)
        XCTAssertEqual(queue.upcomingItems.map(\.id), firstIDs)
    }

    func testQueueSelectionIDResolvesSecondDuplicateOccurrence() async {
        let api = QueueTestPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: StubWebPlaybackCommander())
        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback)
        playback.handle(.ready(deviceID: "device-1"))
        playback.handle(.stateChanged(
            PlaybackNowPlaying(
                name: "Playing",
                artists: ["Artist"],
                albumName: nil,
                albumID: nil,
                albumArtURL: nil,
                durationMilliseconds: 120_000,
                positionMilliseconds: 0,
                uri: "spotify:track:playing"
            ),
            isPaused: false,
            nextTracks: []
        ))
        let first = SpotifyTrack(
            id: "duplicate-1",
            name: "Duplicate one",
            artists: ["Artist"],
            albumArtworkURL: nil,
            durationMilliseconds: 100_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "spotify:track:duplicate"
        )
        let second = SpotifyTrack(
            id: "duplicate-2",
            name: "Duplicate two",
            artists: ["Artist"],
            albumArtworkURL: nil,
            durationMilliseconds: 100_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "spotify:track:duplicate"
        )
        api.queueResponse = SpotifyQueueResponse(queue: [.track(first), .track(second)])

        queue.isPanelVisible = true
        await queue.refreshQueue()
        let selectedID = queue.upcomingItems[1].id

        XCTAssertEqual(queue.item(forSelectionID: selectedID)?.name, "Duplicate two")
    }

    func testQueueViewModelMergesSDKTracksWithAPIQueueSources() async {
        let api = QueueTestPlaybackAPI()
        let commander = StubWebPlaybackCommander()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: commander)
        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback, pollIntervalNanoseconds: 60_000_000_000)

        playback.handle(.ready(deviceID: "device-1"))
        let sdkNext = [
            PlaybackNowPlaying(name: "A", artists: ["a"], albumName: nil, albumID: nil, albumArtURL: nil, durationMilliseconds: 100_000, positionMilliseconds: 0, uri: "spotify:track:a"),
            PlaybackNowPlaying(name: "B", artists: ["b"], albumName: nil, albumID: nil, albumArtURL: nil, durationMilliseconds: 100_000, positionMilliseconds: 0, uri: "spotify:track:b")
        ]
        playback.handle(.stateChanged(
            PlaybackNowPlaying(name: "Cur", artists: ["c"], albumName: nil, albumID: nil, albumArtURL: nil, durationMilliseconds: 120_000, positionMilliseconds: 0, uri: "spotify:track:cur"),
            isPaused: false,
            nextTracks: sdkNext
        ))

        let trackA = SpotifyTrack(id: "a", name: "A", artists: ["a"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:a")
        let trackB = SpotifyTrack(id: "b", name: "B", artists: ["b"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:b")
        let trackC = SpotifyTrack(id: "c", name: "C", artists: ["c"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:c")

        api.queueResponse = SpotifyQueueResponse(queue: [.track(trackA), .track(trackB), .track(trackC)]
        )

        queue.setPanelVisible(true)
        await queue.refreshQueue()

        XCTAssertEqual(queue.upcomingItems.count, 3)
        XCTAssertEqual(queue.upcomingItems[0].uri, "spotify:track:a")
        XCTAssertEqual(queue.upcomingItems[1].uri, "spotify:track:b")
        XCTAssertEqual(queue.upcomingItems[2].uri, "spotify:track:c")
    }

    func testQueueViewModelClearsUpNextWhenRepeatOneDespiteSDKAndAPILists() async throws {
        let api = QueueTestPlaybackAPI()
        let commander = StubWebPlaybackCommander()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: commander)
        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback, pollIntervalNanoseconds: 60_000_000_000)

        playback.handle(.ready(deviceID: "device-1"))
        let sdkNext = [
            PlaybackNowPlaying(name: "A", artists: ["a"], albumName: nil, albumID: nil, albumArtURL: nil, durationMilliseconds: 100_000, positionMilliseconds: 0, uri: "spotify:track:a"),
            PlaybackNowPlaying(name: "B", artists: ["b"], albumName: nil, albumID: nil, albumArtURL: nil, durationMilliseconds: 100_000, positionMilliseconds: 0, uri: "spotify:track:b")
        ]
        playback.handle(.stateChanged(
            PlaybackNowPlaying(name: "Cur", artists: ["c"], albumName: nil, albumID: nil, albumArtURL: nil, durationMilliseconds: 120_000, positionMilliseconds: 0, uri: "spotify:track:cur"),
            isPaused: false,
            nextTracks: sdkNext
        ))

        try await api.setRepeat(mode: .track, deviceID: "device-1")
        await playback.syncTransportFromSpotify()
        XCTAssertEqual(playback.repeatMode, .track)

        let trackA = SpotifyTrack(id: "a", name: "A", artists: ["a"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:a")
        let trackB = SpotifyTrack(id: "b", name: "B", artists: ["b"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:b")
        let trackC = SpotifyTrack(id: "c", name: "C", artists: ["c"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:c")

        api.queueResponse = SpotifyQueueResponse(queue: [.track(trackA), .track(trackB), .track(trackC)]
        )

        queue.setPanelVisible(true)
        await queue.refreshQueue()

        XCTAssertTrue(
            queue.upcomingItems.isEmpty,
            "Repeat-one must hide contextual Up next even when Spotify queue and SDK still list following tracks."
        )
    }

    func testQueueViewModelSyncFromPlaybackSessionAppliesRepeatOneWithoutQueueFetch() async throws {
        let api = QueueTestPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: StubWebPlaybackCommander())
        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback, pollIntervalNanoseconds: 60_000_000_000)

        playback.handle(.ready(deviceID: "device-1"))
        playback.handle(.stateChanged(
            PlaybackNowPlaying(name: "Cur", artists: ["c"], albumName: nil, albumID: nil, albumArtURL: nil, durationMilliseconds: 120_000, positionMilliseconds: 0, uri: "spotify:track:cur"),
            isPaused: false,
            nextTracks: [
                PlaybackNowPlaying(name: "A", artists: ["a"], albumName: nil, albumID: nil, albumArtURL: nil, durationMilliseconds: 100_000, positionMilliseconds: 0, uri: "spotify:track:a")
            ]
        ))

        try await api.setRepeat(mode: .track, deviceID: "device-1")
        await playback.syncTransportFromSpotify()

        queue.syncFromPlaybackSession()

        XCTAssertTrue(queue.upcomingItems.isEmpty)
        XCTAssertFalse(api.actions.contains("fetchQueue"))
    }

    func testQueueViewModelSkipsFetchWhenPanelHidden() async {
        let api = QueueTestPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: StubWebPlaybackCommander())
        playback.handle(.ready(deviceID: "device-1"))
        playback.handle(.stateChanged(
            PlaybackNowPlaying(name: "T", artists: [], albumName: nil, albumID: nil, albumArtURL: nil, durationMilliseconds: 60_000, positionMilliseconds: 0, uri: "spotify:track:t"),
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

        let didFetchQueue = await api.fetchQueueSignal.wait(timeout: .seconds(2))
        XCTAssertTrue(didFetchQueue, "Adding to the queue must trigger a queue refresh.")
        XCTAssertTrue(api.actions.contains("addToQueue:device-42:spotify:track:add-me"))
        XCTAssertTrue(api.actions.filter { $0 == "fetchQueue" }.count >= 1)
    }

    func testQueueViewModelSuppressesDuplicateAddWhileInFlightForSameURI() async {
        let api = QueueTestPlaybackAPI()
        api.addToQueueDelayNanoseconds = 120_000_000
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: StubWebPlaybackCommander())
        playback.handle(.ready(deviceID: "device-1"))
        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback)
        queue.setPanelVisible(true)

        async let first: Void = queue.addToQueue(uri: "spotify:track:dup")
        async let second: Void = queue.addToQueue(uri: "spotify:track:dup")
        _ = await (first, second)

        let enqueueCalls = api.actions.filter { $0 == "addToQueue:device-1:spotify:track:dup" }
        XCTAssertEqual(enqueueCalls.count, 1)
    }

    func testQueueViewModelAllowsConcurrentAddsForDifferentURIs() async {
        let api = QueueTestPlaybackAPI()
        api.addToQueueDelayNanoseconds = 120_000_000
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: StubWebPlaybackCommander())
        playback.handle(.ready(deviceID: "device-1"))
        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback)
        queue.setPanelVisible(true)

        async let first: Void = queue.addToQueue(uri: "spotify:track:a")
        async let second: Void = queue.addToQueue(uri: "spotify:track:b")
        _ = await (first, second)

        XCTAssertEqual(api.actions.filter { $0 == "addToQueue:device-1:spotify:track:a" }.count, 1)
        XCTAssertEqual(api.actions.filter { $0 == "addToQueue:device-1:spotify:track:b" }.count, 1)
    }

    func testQueueViewModelAmbiguousFailureBlocksImmediateRetryToAvoidDuplicateSubmission() async {
        let api = QueueTestPlaybackAPI()
        api.addToQueueErrors = [URLError(.timedOut), nil]
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: StubWebPlaybackCommander())
        playback.handle(.ready(deviceID: "device-1"))
        let queue = QueueViewModel(
            playbackAPI: api,
            playbackSession: playback,
            enqueueUnknownOutcomeCooldown: .milliseconds(300)
        )
        queue.setPanelVisible(true)

        await queue.addToQueue(uri: "spotify:track:ambiguous")
        await queue.addToQueue(uri: "spotify:track:ambiguous")

        let enqueueCalls = api.actions.filter { $0 == "addToQueue:device-1:spotify:track:ambiguous" }
        XCTAssertEqual(enqueueCalls.count, 1)
        XCTAssertEqual(queue.lastError?.title, "Queue status pending")
    }

    func testQueueTransientRefreshFailurePreservesSameSessionCachedRows() async {
        let api = QueueTestPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: StubWebPlaybackCommander())
        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback)
        playback.handle(.ready(deviceID: "device-1"))
        playback.handle(.stateChanged(
            PlaybackNowPlaying(
                name: "Current",
                artists: ["Artist"],
                albumName: nil,
                albumID: nil,
                albumArtURL: nil,
                durationMilliseconds: 120_000,
                positionMilliseconds: 0,
                uri: "spotify:track:current"
            ),
            isPaused: false,
            nextTracks: []
        ))
        let cached = SpotifyTrack(
            id: "cached",
            name: "Cached",
            artists: ["Artist"],
            albumArtworkURL: nil,
            durationMilliseconds: 100_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "spotify:track:cached"
        )
        api.queueResponse = SpotifyQueueResponse(queue: [.track(cached)])
        queue.isPanelVisible = true
        await queue.refreshQueue()
        api.errorToThrow = URLError(.timedOut)

        await queue.refreshQueue()

        XCTAssertEqual(queue.upcomingItems.map(\.uri), [cached.uri])
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
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 100_000,
            positionMilliseconds: 0,
            uri: "spotify:track:old"
        )
        playback.handle(.stateChanged(oldNow, isPaused: false, nextTracks: [
            PlaybackNowPlaying(name: "Next", artists: ["B"], albumName: nil, albumID: nil, albumArtURL: nil, durationMilliseconds: 100_000, positionMilliseconds: 0, uri: "spotify:track:next")
        ]))

        let oldTrack = SpotifyTrack(id: "old", name: "Old", artists: ["A"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:old")
        let nextTrack = SpotifyTrack(id: "next", name: "Next", artists: ["B"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:next")
        let thirdTrack = SpotifyTrack(id: "third", name: "Third", artists: ["C"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:third")
        api.queueResponse = SpotifyQueueResponse(queue: [.track(nextTrack), .track(thirdTrack)])

        queue.setPanelVisible(true)
        await queue.refreshQueue()

        let newNow = PlaybackNowPlaying(
            name: "Next",
            artists: ["B"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 100_000,
            positionMilliseconds: 0,
            uri: "spotify:track:next"
        )
        playback.handle(.stateChanged(newNow, isPaused: false, nextTracks: [
            PlaybackNowPlaying(name: "Third", artists: ["C"], albumName: nil, albumID: nil, albumArtURL: nil, durationMilliseconds: 100_000, positionMilliseconds: 0, uri: "spotify:track:third")
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
        api.queueResponse = SpotifyQueueResponse(queue: [.track(one), .track(two), .track(three)])
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
        api.queueResponse = SpotifyQueueResponse(queue: [.track(one), .track(two), .track(three)])
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

    func testQueueShuffleDoesNotRefreshBeforeTransportStateIsKnown() async {
        let api = MockPlaybackAPI()
        api.fetchPlayerSnapshotError = SpotifyAPIError.network("offline")
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: MockWebPlaybackCommander())
        playback.handle(.ready(deviceID: "device-1"))
        let queue = QueueViewModel(
            playbackAPI: api,
            playbackSession: playback,
            pollIntervalNanoseconds: 60_000_000_000
        )

        await queue.toggleShuffle()

        XCTAssertFalse(api.actions.contains("fetchQueue"))
        XCTAssertFalse(api.actions.contains { $0.hasPrefix("setShuffle:") })
    }

    func testQueueShuffleFailureRestoresPreviousOrdering() async {
        let api = QueueTestPlaybackAPI()
        api.setShuffleError = SpotifyAPIError.notFound(message: nil)
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: StubWebPlaybackCommander(), postShuffleSyncDelay: .seconds(10))
        playback.handle(.ready(deviceID: "device-1"))
        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback, pollIntervalNanoseconds: 60_000_000_000)

        let one = SpotifyTrack(id: "1", name: "One", artists: ["A"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:1")
        let two = SpotifyTrack(id: "2", name: "Two", artists: ["B"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:2")
        api.queueResponse = SpotifyQueueResponse(queue: [.track(one), .track(two)])
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
        let originalQueue = SpotifyQueueResponse(queue: [.track(one), .track(two), .track(three)])
        let shuffledQueue = SpotifyQueueResponse(queue: [.track(three), .track(one), .track(two)])
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

    func testQueueRefreshCoalescesConcurrentManualRequests() async {
        let api = QueueTestPlaybackAPI()
        api.fetchQueueDelayNanoseconds = 80_000_000
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: StubWebPlaybackCommander())
        playback.handle(.ready(deviceID: "device-1"))
        playback.handle(.stateChanged(
            PlaybackNowPlaying(name: "T", artists: ["A"], albumName: nil, albumID: nil, albumArtURL: nil, durationMilliseconds: 60_000, positionMilliseconds: 0, uri: "spotify:track:t"),
            isPaused: false,
            nextTracks: []
        ))
        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback, pollIntervalNanoseconds: 60_000_000_000, pollJitterFraction: 0)
        queue.setPanelVisible(true)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await queue.refreshQueue() }
            group.addTask { await queue.refreshQueue() }
        }

        XCTAssertFalse(api.concurrentFetchDetected, "Queue refreshes should never overlap in-flight network requests.")
        XCTAssertEqual(api.maxConcurrentFetches, 1)
    }

    func testQueueRefreshShortCircuitsDuringRateLimitCooldown() async {
        let api = QueueTestPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: StubWebPlaybackCommander())
        playback.handle(.ready(deviceID: "device-1"))
        playback.handle(.stateChanged(
            PlaybackNowPlaying(name: "T", artists: ["A"], albumName: nil, albumID: nil, albumArtURL: nil, durationMilliseconds: 60_000, positionMilliseconds: 0, uri: "spotify:track:t"),
            isPaused: false,
            nextTracks: []
        ))
        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback, pollJitterFraction: 0, defaultRateLimitCooldownSeconds: 0.3)
        queue.setPanelVisible(true)

        api.errorToThrow = SpotifyAPIError.rateLimited(retryAfter: 0.3)
        await queue.refreshQueue()
        let fetchesAfterFirstFailure = api.actions.filter { $0 == "fetchQueue" }.count

        await queue.refreshQueue()
        let fetchesAfterSecondAttempt = api.actions.filter { $0 == "fetchQueue" }.count

        XCTAssertEqual(fetchesAfterFirstFailure, 1)
        XCTAssertEqual(fetchesAfterSecondAttempt, 1, "Manual refresh should yield to cooldown instead of calling Spotify again immediately.")
        XCTAssertEqual(queue.lastError?.title, "Rate limited")
    }

    func testQueuePollingStopsWhenAppBecomesInactive() async {
        let api = QueueTestPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: StubWebPlaybackCommander())
        playback.handle(.ready(deviceID: "device-1"))
        playback.handle(.stateChanged(
            PlaybackNowPlaying(name: "T", artists: ["A"], albumName: nil, albumID: nil, albumArtURL: nil, durationMilliseconds: 60_000, positionMilliseconds: 0, uri: "spotify:track:t"),
            isPaused: false,
            nextTracks: []
        ))
        let queue = QueueViewModel(
            playbackAPI: api,
            playbackSession: playback,
            pollIntervalNanoseconds: 30_000_000,
            pausedPollIntervalNanoseconds: 30_000_000,
            pollJitterFraction: 0
        )
        queue.setPanelVisible(true)
        await queue.refreshQueue()
        try? await Task.sleep(nanoseconds: 80_000_000)
        let fetchesBeforeInactive = api.actions.filter { $0 == "fetchQueue" }.count

        queue.setAppActive(false)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let fetchesAfterInactive = api.actions.filter { $0 == "fetchQueue" }.count

        XCTAssertGreaterThan(fetchesBeforeInactive, 0)
        XCTAssertLessThanOrEqual(
            fetchesAfterInactive - fetchesBeforeInactive,
            1,
            "Polling should stop when app resigns active; at most one in-flight fetch may complete."
        )
    }

    func testQueueViewModelPlayItemDelegatesToPlaybackSession() async {
        let api = QueueTestPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: StubWebPlaybackCommander())
        playback.handle(.ready(deviceID: "device-1"))
        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback)
        let item = QueueItem.from(track: SpotifyTrack(
            id: "t",
            name: "Track",
            artists: ["A"],
            albumArtworkURL: nil,
            durationMilliseconds: 60_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "spotify:track:play-me"
        ))

        await queue.playItem(item)

        XCTAssertTrue(api.actions.contains("transfer:device-1:false"))
        XCTAssertTrue(api.actions.contains("play:device-1:spotify:track:play-me"))
    }

    func testQueueViewModelAddToQueueWithoutDeviceShowsPlaybackUnavailable() async {
        let api = QueueTestPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: StubWebPlaybackCommander())
        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback)

        await queue.addToQueue(uri: "spotify:track:x")

        XCTAssertEqual(queue.lastError?.title, "Playback unavailable")
        XCTAssertFalse(api.actions.contains(where: { $0.hasPrefix("addToQueue:") }))
    }

    func testQueuePrefetchForLyricsAllowsHiddenPanelFetch() async {
        let api = QueueTestPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: StubWebPlaybackCommander())
        playback.handle(.ready(deviceID: "device-1"))
        playback.handle(.stateChanged(
            PlaybackNowPlaying(name: "T", artists: [], albumName: nil, albumID: nil, albumArtURL: nil, durationMilliseconds: 60_000, positionMilliseconds: 0, uri: "spotify:track:t"),
            isPaused: false,
            nextTracks: []
        ))
        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback)
        queue.setPanelVisible(false)

        await queue.prefetchQueueForLyricsOverlay()

        XCTAssertTrue(api.actions.contains("fetchQueue"))
    }

    func testQueueOptimisticReconcileClearsAfterTimeout() async {
        let api = QueueTestPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: StubWebPlaybackCommander(), postShuffleSyncDelay: .seconds(10))
        playback.handle(.ready(deviceID: "device-1"))
        let queue = QueueViewModel(
            playbackAPI: api,
            playbackSession: playback,
            optimisticReconcileTimeout: .milliseconds(40)
        )

        let one = SpotifyTrack(id: "1", name: "One", artists: ["A"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:1")
        let two = SpotifyTrack(id: "2", name: "Two", artists: ["B"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:2")
        api.queueResponse = SpotifyQueueResponse(queue: [.track(one), .track(two)])
        queue.setPanelVisible(true)
        await queue.refreshQueue()
        let original = queue.upcomingItems.map(\.id)

        await queue.toggleShuffle()
        let optimistic = queue.upcomingItems.map(\.id)
        XCTAssertNotEqual(optimistic, original)

        try? await Task.sleep(nanoseconds: 60_000_000)
        await queue.refreshQueue()
        XCTAssertEqual(queue.upcomingItems.map(\.id), original, "Optimistic projection should clear after reconcile timeout.")
    }

    func testQueueRefreshMapsUnauthorizedAPIError() async {
        let api = QueueTestPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: StubWebPlaybackCommander())
        playback.handle(.ready(deviceID: "device-1"))
        playback.handle(.stateChanged(
            PlaybackNowPlaying(name: "T", artists: [], albumName: nil, albumID: nil, albumArtURL: nil, durationMilliseconds: 60_000, positionMilliseconds: 0, uri: "spotify:track:t"),
            isPaused: false,
            nextTracks: []
        ))
        let queue = QueueViewModel(playbackAPI: api, playbackSession: playback)
        queue.setPanelVisible(true)
        api.errorToThrow = SpotifyAPIError.unauthorized

        await queue.refreshQueue()

        XCTAssertEqual(queue.lastError?.title, "Sign in again")
    }

    func testCancelledQueuePollDoesNotRefreshImmediately() async {
        let api = QueueTestPlaybackAPI()
        let playback = PlaybackSessionViewModel(playbackAPI: api, webCommander: StubWebPlaybackCommander())
        playback.handle(.ready(deviceID: "device-1"))
        playback.handle(.stateChanged(
            PlaybackNowPlaying(name: "T", artists: ["A"], albumName: nil, albumID: nil, albumArtURL: nil, durationMilliseconds: 60_000, positionMilliseconds: 0, uri: "spotify:track:t"),
            isPaused: false,
            nextTracks: []
        ))
        let queue = QueueViewModel(
            playbackAPI: api,
            playbackSession: playback,
            pollIntervalNanoseconds: 60_000_000_000,
            pollJitterFraction: 0
        )
        queue.setPanelVisible(true)
        await queue.refreshQueue()
        try? await Task.sleep(nanoseconds: 20_000_000)
        let baselineFetchCount = api.actions.filter { $0 == "fetchQueue" }.count

        queue.setPanelVisible(false)
        try? await Task.sleep(nanoseconds: 50_000_000)

        let fetchCountAfterCancel = api.actions.filter { $0 == "fetchQueue" }.count
        XCTAssertEqual(
            fetchCountAfterCancel,
            baselineFetchCount,
            "Cancelling the queue poll task during sleep must not trigger an immediate GET /v1/me/player/queue."
        )
    }
}

private final class StubWebPlaybackCommander: WebPlaybackCommanding {
    func loadHost(generation: PlaybackHostGeneration) {}

    func send(_ command: PlaybackBridgeCommand, payload: [String: Any]) async throws {}
}

private final class QueueTestPlaybackAPI: SpotifyPlaybackControlling {
    private let lock = NSLock()
    private(set) var actions: [String] = []
    let fetchQueueSignal = AsyncSignal()
    var queueResponse = SpotifyQueueResponse(queue: [])
    var errorToThrow: Error?
    var setShuffleError: Error?
    var setRepeatError: Error?
    var fetchQueueDelayNanoseconds: UInt64 = 0
    var queueResponses: [SpotifyQueueResponse] = []
    var addToQueueDelayNanoseconds: UInt64 = 0
    var addToQueueErrors: [Error?] = []
    private(set) var concurrentFetchDetected = false
    private(set) var maxConcurrentFetches = 0
    private var currentConcurrentFetches = 0
    private var reportedTransport = SpotifyPlayerTransport(shuffle: false, repeatMode: .off)

    func transferPlayback(to deviceID: String, play: Bool) async throws {
        appendAction("transfer:\(deviceID):\(play)")
    }

    func play(uri: String, deviceID: String) async throws {
        appendAction("play:\(deviceID):\(uri)")
    }

    func play(contextURI: String, deviceID: String) async throws {
        appendAction("play-context:\(deviceID):\(contextURI)")
    }

    func play(uris: [String], deviceID: String) async throws {
        appendAction("play-list:\(deviceID):\(uris.joined(separator: ","))")
    }

    func seek(to milliseconds: Int, deviceID: String) async throws {}

    func next(deviceID: String) async throws {}

    func previous(deviceID: String) async throws {}

    func fetchQueue() async throws -> SpotifyQueueResponse {
        appendAction("fetchQueue")
        fetchQueueSignal.signal()
        beginFetch()
        defer { endFetch() }
        if fetchQueueDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: fetchQueueDelayNanoseconds)
        }
        if let errorToThrow {
            throw errorToThrow
        }
        if let next = dequeueQueueResponse() {
            return next
        }
        return readQueueResponse()
    }

    func addToQueue(uri: String, deviceID: String) async throws {
        // Track attempted submissions so ambiguous transport failures are visible in tests.
        appendAction("addToQueue:\(deviceID):\(uri)")
        if addToQueueDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: addToQueueDelayNanoseconds)
        }
        if let error = dequeueAddToQueueError() {
            throw error
        }
    }

    func fetchPlayerSnapshot() async throws -> SpotifyPlayerSnapshot? {
        appendAction("fetchPlayerSnapshot")
        return SpotifyPlayerSnapshot(transport: readReportedTransport(), activeDevice: nil, isPlaying: true)
    }

    func fetchAvailableDevices() async throws -> [SpotifyConnectDevice] {
        appendAction("fetchAvailableDevices")
        return []
    }

    func setShuffle(enabled: Bool, deviceID: String) async throws {
        if let setShuffleError { throw setShuffleError }
        appendAction("setShuffle:\(deviceID):\(enabled)")
        writeReportedTransport(SpotifyPlayerTransport(shuffle: enabled, repeatMode: readReportedTransport().repeatMode))
    }

    func setRepeat(mode: SpotifyRepeatMode, deviceID: String) async throws {
        if let setRepeatError { throw setRepeatError }
        appendAction("setRepeat:\(deviceID):\(mode.rawValue)")
        writeReportedTransport(SpotifyPlayerTransport(shuffle: readReportedTransport().shuffle, repeatMode: mode))
    }

    private func appendAction(_ action: String) {
        lock.lock()
        actions.append(action)
        lock.unlock()
    }

    private func beginFetch() {
        lock.lock()
        currentConcurrentFetches += 1
        maxConcurrentFetches = max(maxConcurrentFetches, currentConcurrentFetches)
        if currentConcurrentFetches > 1 {
            concurrentFetchDetected = true
        }
        lock.unlock()
    }

    private func endFetch() {
        lock.lock()
        currentConcurrentFetches -= 1
        lock.unlock()
    }

    private func dequeueQueueResponse() -> SpotifyQueueResponse? {
        lock.lock()
        defer { lock.unlock() }
        guard !queueResponses.isEmpty else { return nil }
        return queueResponses.removeFirst()
    }

    private func readQueueResponse() -> SpotifyQueueResponse {
        lock.lock()
        defer { lock.unlock() }
        return queueResponse
    }

    private func dequeueAddToQueueError() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        guard !addToQueueErrors.isEmpty else { return nil }
        return addToQueueErrors.removeFirst()
    }

    private func readReportedTransport() -> SpotifyPlayerTransport {
        lock.lock()
        defer { lock.unlock() }
        return reportedTransport
    }

    private func writeReportedTransport(_ value: SpotifyPlayerTransport) {
        lock.lock()
        reportedTransport = value
        lock.unlock()
    }
}
