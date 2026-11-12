import SwiftUI
import ViewInspector
import XCTest
@testable import Spotiglass

@MainActor
final class QueuePanelTests: XCTestCase {
    func testQueueTrackProjectsIntoSharedMutationTarget() {
        let item = QueueItem(
            id: "queue:rest:occurrence:0",
            name: "Queued Track",
            subtitle: "Artist",
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            uri: "  spotify:track:queued  ",
            artistTapTargets: [ArtistTapTarget(id: "artist-1", name: "Artist")]
        )

        let row = TrackRowViewModel(queueItem: item)

        XCTAssertEqual(row.id, item.id)
        XCTAssertEqual(row.spotifyTrackID, "queued")
        XCTAssertEqual(row.playableURI, "spotify:track:queued")
        XCTAssertEqual(row.artistRefs, [MusicArtistRef(id: "artist-1", name: "Artist")])
    }

    func testQueueTrackOptionsUseTheProjectedRowWithoutMove() throws {
        let item = QueueItem(
            name: "Queued Track",
            subtitle: "Artist",
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            uri: "spotify:track:queued"
        )
        let browserViewModel = PlaylistBrowserViewModel(
            api: MockBrowsingAPI(playlistResults: [], trackResults: [:]),
            cache: MockBrowsingCache()
        )
        let menu = TrackOpsMenuItems(
            targets: [TrackRowViewModel(queueItem: item)],
            browserViewModel: browserViewModel,
            sourcePlaylistID: nil
        )
        .environmentObject(PinnedItemsStore(cache: InMemoryPinnedItemsCache()))

        XCTAssertNoThrow(try menu.inspect().find(text: SpotiglassL10n.string("browser.addToPlaylist")))
        XCTAssertThrowsError(
            try menu.inspect().find(text: SpotiglassL10n.string("browser.moveToPlaylist"))
        )
    }

    func testQueueItemArtistTapTargetsPreferArtistRefs() {
        let track = MusicTrack(
            id: "track-1",
            name: "Track",
            artists: ["Shown Name"],
            artistRefs: [MusicArtistRef(id: "artist-1", name: "Resolved Artist")],
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
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: StubWebPlaybackCommander()))
        let queue = QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api), playbackSession: playback, pollIntervalNanoseconds: 60_000_000_000)

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
        let next = MusicTrack(
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
        api.queueResponse = MusicPlaybackQueue(queue: [.track(next)])

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
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: StubWebPlaybackCommander()))
        let queue = QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api), playbackSession: playback)
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
        queue.lastFetchedQueue = MusicPlaybackQueue(queue: [])
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
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: StubWebPlaybackCommander()))
        let queue = QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api), playbackSession: playback, pollIntervalNanoseconds: 60_000_000_000)

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
        let oldNext = MusicTrack(
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
        api.queueResponse = MusicPlaybackQueue(queue: [.track(oldNext)])
        queue.lastFetchedQueue = api.queueResponse
        queue.publishMergedState()
        queue.isPanelVisible = true

        let staleFetch = MockCallHold()
        api.fetchQueueHold = staleFetch
        let refreshTask = Task { await queue.refreshQueue() }
        let fetchStarted = await staleFetch.entered.wait(timeout: .seconds(5))
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
        staleFetch.release()

        await refreshTask.value

        XCTAssertNil(queue.lastFetchedQueue)
        XCTAssertFalse(queue.upcomingItems.contains(where: { $0.uri == oldNext.uri }))
    }

    func testQueueIgnoresStaleFetchErrorAfterDisconnectBeforeReconnect() async {
        let api = QueueTestPlaybackAPI()
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: StubWebPlaybackCommander()))
        let queue = QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api), playbackSession: playback, pollIntervalNanoseconds: 60_000_000_000)

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
        let staleFetch = MockCallHold()
        api.fetchQueueHold = staleFetch
        api.errorToThrow = SpotifyAPIError.unauthorized

        let refreshTask = Task { await queue.refreshQueue() }
        let fetchStarted = await staleFetch.entered.wait(timeout: .seconds(5))
        XCTAssertTrue(fetchStarted)
        queue.isPanelVisible = false

        await playback.disconnect()
        queue.handlePlaybackStateChange()
        playback.handle(.ready(deviceID: "device-2"))
        queue.handlePlaybackStateChange()
        staleFetch.release()

        await refreshTask.value

        XCTAssertNil(queue.lastError)
    }

    func testSDKProjectionRetainsCurrentURIAndDuplicateOccurrences() {
        let api = QueueTestPlaybackAPI()
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: StubWebPlaybackCommander()))
        let queue = QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api), playbackSession: playback)
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
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: StubWebPlaybackCommander()))
        let queue = QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api), playbackSession: playback, pollIntervalNanoseconds: 60_000_000_000)

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
        let currentTrack = MusicTrack(
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
        let duplicateTrack = MusicTrack(
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
        let nextTrack = MusicTrack(
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
        api.queueResponse = MusicPlaybackQueue(
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
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: StubWebPlaybackCommander()))
        let queue = QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api), playbackSession: playback)
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
        let first = MusicTrack(
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
        let second = MusicTrack(
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
        api.queueResponse = MusicPlaybackQueue(queue: [.track(first), .track(second)])

        queue.isPanelVisible = true
        await queue.refreshQueue()
        let selectedID = queue.upcomingItems[1].id

        XCTAssertEqual(queue.item(forSelectionID: selectedID)?.name, "Duplicate two")
    }

    func testQueueViewModelMergesSDKTracksWithAPIQueueSources() async {
        let api = QueueTestPlaybackAPI()
        let commander = StubWebPlaybackCommander()
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: commander))
        let queue = QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api), playbackSession: playback, pollIntervalNanoseconds: 60_000_000_000)

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

        let trackA = MusicTrack(id: "a", name: "A", artists: ["a"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:a")
        let trackB = MusicTrack(id: "b", name: "B", artists: ["b"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:b")
        let trackC = MusicTrack(id: "c", name: "C", artists: ["c"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:c")

        api.queueResponse = MusicPlaybackQueue(queue: [.track(trackA), .track(trackB), .track(trackC)]
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
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: commander))
        let queue = QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api), playbackSession: playback, pollIntervalNanoseconds: 60_000_000_000)

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

        let trackA = MusicTrack(id: "a", name: "A", artists: ["a"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:a")
        let trackB = MusicTrack(id: "b", name: "B", artists: ["b"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:b")
        let trackC = MusicTrack(id: "c", name: "C", artists: ["c"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:c")

        api.queueResponse = MusicPlaybackQueue(queue: [.track(trackA), .track(trackB), .track(trackC)]
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
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: StubWebPlaybackCommander()))
        let queue = QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api), playbackSession: playback, pollIntervalNanoseconds: 60_000_000_000)

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
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: StubWebPlaybackCommander()))
        playback.handle(.ready(deviceID: "device-1"))
        playback.handle(.stateChanged(
            PlaybackNowPlaying(name: "T", artists: [], albumName: nil, albumID: nil, albumArtURL: nil, durationMilliseconds: 60_000, positionMilliseconds: 0, uri: "spotify:track:t"),
            isPaused: false,
            nextTracks: []
        ))

        let queue = QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api), playbackSession: playback, pollIntervalNanoseconds: 50_000_000)
        queue.setPanelVisible(false)
        await queue.refreshQueue()

        XCTAssertFalse(api.actions.contains("fetchQueue"))
    }

    func testQueueViewModelAddToQueueUsesDeviceIDAndRefetches() async {
        let api = QueueTestPlaybackAPI()
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: StubWebPlaybackCommander()))
        playback.handle(.ready(deviceID: "device-42"))

        let queue = QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api), playbackSession: playback)
        queue.setPanelVisible(true)

        await queue.addToQueue(uri: "spotify:track:add-me")

        let didFetchQueue = await api.fetchQueueSignal.wait(timeout: .seconds(30))
        XCTAssertTrue(didFetchQueue, "Adding to the queue must trigger a queue refresh.")
        XCTAssertTrue(api.actions.contains("addToQueue:device-42:spotify:track:add-me"))
        XCTAssertTrue(api.actions.filter { $0 == "fetchQueue" }.count >= 1)
    }

    func testQueueViewModelSuppressesDuplicateAddWhileInFlightForSameURI() async {
        let api = QueueTestPlaybackAPI()
        let firstAdd = MockCallHold()
        api.addToQueueHold = firstAdd
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: StubWebPlaybackCommander()))
        playback.handle(.ready(deviceID: "device-1"))
        let queue = QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api), playbackSession: playback)
        queue.setPanelVisible(true)

        let first = Task { await queue.addToQueue(uri: "spotify:track:dup") }
        let didSendFirstAdd = await firstAdd.entered.wait(timeout: .seconds(5))
        XCTAssertTrue(didSendFirstAdd, "the first add should be in flight before the duplicate")
        await queue.addToQueue(uri: "spotify:track:dup")
        firstAdd.release()
        await first.value

        let enqueueCalls = api.actions.filter { $0 == "addToQueue:device-1:spotify:track:dup" }
        XCTAssertEqual(enqueueCalls.count, 1)
    }

    func testQueueViewModelAllowsConcurrentAddsForDifferentURIs() async {
        let api = QueueTestPlaybackAPI()
        let firstAdd = MockCallHold()
        api.addToQueueHold = firstAdd
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: StubWebPlaybackCommander()))
        playback.handle(.ready(deviceID: "device-1"))
        let queue = QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api), playbackSession: playback)
        queue.setPanelVisible(true)

        let first = Task { await queue.addToQueue(uri: "spotify:track:a") }
        let didSendFirstAdd = await firstAdd.entered.wait(timeout: .seconds(5))
        XCTAssertTrue(didSendFirstAdd, "the add for a should be in flight before the add for b")
        // The add for b reaching the API releases the held add for a.
        let secondDone = AsyncSignal()
        let second = Task {
            await queue.addToQueue(uri: "spotify:track:b")
            secondDone.signal()
        }
        let didFinishSecondAdd = await secondDone.wait(timeout: .seconds(5))
        XCTAssertTrue(didFinishSecondAdd, "the add for b should not wait for the add for a")
        firstAdd.release()
        await first.value
        await second.value

        XCTAssertEqual(api.actions.filter { $0 == "addToQueue:device-1:spotify:track:a" }.count, 1)
        XCTAssertEqual(api.actions.filter { $0 == "addToQueue:device-1:spotify:track:b" }.count, 1)
    }

    func testQueueViewModelAmbiguousFailureBlocksImmediateRetryToAvoidDuplicateSubmission() async {
        let api = QueueTestPlaybackAPI()
        api.addToQueueErrors = [URLError(.timedOut), nil]
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: StubWebPlaybackCommander()))
        playback.handle(.ready(deviceID: "device-1"))
        let queue = QueueViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api),
            playbackSession: playback,
            enqueueUnknownOutcomeCooldown: .milliseconds(300),
            clock: ManualPlaybackClock()
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
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: StubWebPlaybackCommander()))
        let queue = QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api), playbackSession: playback)
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
        let cached = MusicTrack(
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
        api.queueResponse = MusicPlaybackQueue(queue: [.track(cached)])
        queue.isPanelVisible = true
        await queue.refreshQueue()
        api.errorToThrow = URLError(.timedOut)

        await queue.refreshQueue()

        XCTAssertEqual(queue.upcomingItems.map(\.uri), [cached.uri])
    }

    func testQueueViewModelDoesNotShowErrorBannerForCancellation() async {
        let api = QueueTestPlaybackAPI()
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: StubWebPlaybackCommander()))
        playback.handle(.ready(deviceID: "device-1"))

        let queue = QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api), playbackSession: playback)
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
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: StubWebPlaybackCommander()))
        let queue = QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api), playbackSession: playback, pollIntervalNanoseconds: 60_000_000_000)
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

        let oldTrack = MusicTrack(id: "old", name: "Old", artists: ["A"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:old")
        let nextTrack = MusicTrack(id: "next", name: "Next", artists: ["B"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:next")
        let thirdTrack = MusicTrack(id: "third", name: "Third", artists: ["C"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:third")
        api.queueResponse = MusicPlaybackQueue(queue: [.track(nextTrack), .track(thirdTrack)])

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
        let clock = ManualPlaybackClock()
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: StubWebPlaybackCommander()), clock: clock, postShuffleSyncDelay: .seconds(10))
        playback.handle(.ready(deviceID: "device-1"))
        // Shuffle needs the transport state, which the initial read brings.
        await playback.syncTransportFromSpotify()
        XCTAssertTrue(playback.isTransportMutationReady)
        let queue = QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api), playbackSession: playback, pollIntervalNanoseconds: 60_000_000_000, clock: clock)

        let one = MusicTrack(id: "1", name: "One", artists: ["A"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:1")
        let two = MusicTrack(id: "2", name: "Two", artists: ["B"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:2")
        let three = MusicTrack(id: "3", name: "Three", artists: ["C"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:3")
        api.queueResponse = MusicPlaybackQueue(queue: [.track(one), .track(two), .track(three)])
        queue.isPanelVisible = true
        await queue.refreshQueue()
        let original = queue.upcomingItems.map(\.id)
        XCTAssertGreaterThan(original.count, 1, "Test requires multiple upcoming items.")
        let reconciliationFetch = MockCallHold()
        api.fetchQueueHold = reconciliationFetch

        let toggleTask = Task { await queue.toggleShuffle() }
        let didStartShuffleFetch = await reconciliationFetch.entered.wait(timeout: .seconds(5))
        XCTAssertTrue(
            didStartShuffleFetch,
            "shuffle should start queue reconciliation after applying its optimistic order"
        )
        XCTAssertNotEqual(
            queue.upcomingItems.map(\.id),
            original,
            "Queue should reorder before slow Spotify reconciliation finishes."
        )
        reconciliationFetch.release()
        await toggleTask.value
    }

    func testQueueShuffleOffRestoresPreShuffleSnapshotImmediately() async {
        let api = QueueTestPlaybackAPI()
        let clock = ManualPlaybackClock()
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: StubWebPlaybackCommander()), clock: clock, postShuffleSyncDelay: .seconds(10))
        playback.handle(.ready(deviceID: "device-1"))
        // Shuffle needs the transport state, which the initial read brings.
        await playback.syncTransportFromSpotify()
        XCTAssertTrue(playback.isTransportMutationReady)
        let queue = QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api), playbackSession: playback, pollIntervalNanoseconds: 60_000_000_000, clock: clock)

        let one = MusicTrack(id: "1", name: "One", artists: ["A"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:1")
        let two = MusicTrack(id: "2", name: "Two", artists: ["B"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:2")
        let three = MusicTrack(id: "3", name: "Three", artists: ["C"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:3")
        api.queueResponse = MusicPlaybackQueue(queue: [.track(one), .track(two), .track(three)])
        queue.isPanelVisible = true
        await queue.refreshQueue()
        let original = queue.upcomingItems.map(\.id)
        XCTAssertGreaterThan(original.count, 1, "Test requires multiple upcoming items.")
        api.errorToThrow = CancellationError()
        await queue.toggleShuffle()

        let reconciliationFetch = MockCallHold()
        api.fetchQueueHold = reconciliationFetch
        let offTask = Task { await queue.toggleShuffle() }
        let didStartShuffleOffFetch = await reconciliationFetch.entered.wait(timeout: .seconds(5))
        XCTAssertTrue(
            didStartShuffleOffFetch,
            "turning shuffle off should start queue reconciliation after restoring its snapshot"
        )
        XCTAssertEqual(
            queue.upcomingItems.map(\.id),
            original,
            "Turning shuffle off should restore pre-shuffle ordering before reconciliation finishes."
        )
        reconciliationFetch.release()
        await offTask.value
    }

    func testQueueShuffleDoesNotRefreshBeforeTransportStateIsKnown() async {
        let api = MockPlaybackAPI()
        api.fetchPlayerSnapshotError = SpotifyAPIError.network("offline")
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()))
        playback.handle(.ready(deviceID: "device-1"))
        let queue = QueueViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api),
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
        let clock = ManualPlaybackClock()
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: StubWebPlaybackCommander()), clock: clock, postShuffleSyncDelay: .seconds(10))
        playback.handle(.ready(deviceID: "device-1"))
        let queue = QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api), playbackSession: playback, pollIntervalNanoseconds: 60_000_000_000, clock: clock)

        let one = MusicTrack(id: "1", name: "One", artists: ["A"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:1")
        let two = MusicTrack(id: "2", name: "Two", artists: ["B"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:2")
        api.queueResponse = MusicPlaybackQueue(queue: [.track(one), .track(two)])
        queue.setPanelVisible(true)
        await queue.refreshQueue()
        let original = queue.upcomingItems.map(\.id)

        await queue.toggleShuffle()

        XCTAssertEqual(queue.upcomingItems.map(\.id), original)
        XCTAssertFalse(playback.shuffleEnabled)
    }

    func testQueueShuffleDoesNotSnapBackOnFirstStaleReconciliationFetch() async {
        let api = QueueTestPlaybackAPI()
        let clock = ManualPlaybackClock()
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: StubWebPlaybackCommander()), clock: clock, postShuffleSyncDelay: .seconds(10))
        playback.handle(.ready(deviceID: "device-1"))
        // Shuffle needs the transport state, which the initial read brings.
        await playback.syncTransportFromSpotify()
        XCTAssertTrue(playback.isTransportMutationReady)
        let queue = QueueViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api),
            playbackSession: playback,
            pollIntervalNanoseconds: 60_000_000_000,
            optimisticReconcileTimeout: .seconds(5),
            clock: clock
        )

        let one = MusicTrack(id: "1", name: "One", artists: ["A"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:1")
        let two = MusicTrack(id: "2", name: "Two", artists: ["B"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:2")
        let three = MusicTrack(id: "3", name: "Three", artists: ["C"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:3")
        let originalQueue = MusicPlaybackQueue(queue: [.track(one), .track(two), .track(three)])
        let shuffledQueue = MusicPlaybackQueue(queue: [.track(three), .track(one), .track(two)])
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
        let firstFetch = MockCallHold()
        api.fetchQueueHold = firstFetch
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: StubWebPlaybackCommander()))
        playback.handle(.ready(deviceID: "device-1"))
        playback.handle(.stateChanged(
            PlaybackNowPlaying(name: "T", artists: ["A"], albumName: nil, albumID: nil, albumArtURL: nil, durationMilliseconds: 60_000, positionMilliseconds: 0, uri: "spotify:track:t"),
            isPaused: false,
            nextTracks: []
        ))
        let queue = QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api), playbackSession: playback, pollIntervalNanoseconds: 60_000_000_000, pollJitterFraction: 0)
        queue.setPanelVisible(true)

        // Each refresh runs at once up to its fetch or its wait, so the second one arrives
        // while the first one's fetch is in flight.
        let first = Task.immediate { await queue.refreshQueue() }
        let didStartFirstFetch = await firstFetch.entered.wait(timeout: .seconds(5))
        XCTAssertTrue(didStartFirstFetch, "the first refresh should be fetching before the second")
        let second = Task.immediate { await queue.refreshQueue() }
        firstFetch.release()
        await first.value
        await second.value

        XCTAssertFalse(api.concurrentFetchDetected, "Queue refreshes should never overlap in-flight network requests.")
        XCTAssertEqual(api.maxConcurrentFetches, 1)
    }

    /// The failure behind the flaky coalescing test: a manual refresh that
    /// joined an in-flight refresh returned at once, before any fetch it asked
    /// for had run. It now returns only after its follow-up fetch finished.
    func testManualRefreshThatJoinsAnInFlightRefreshWaitsForItsFollowUpFetch() async {
        let api = QueueTestPlaybackAPI()
        let gate = AsyncSignal()
        api.fetchQueueGate = gate
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: StubWebPlaybackCommander()))
        playback.handle(.ready(deviceID: "device-1"))
        playback.handle(.stateChanged(
            PlaybackNowPlaying(name: "T", artists: ["A"], albumName: nil, albumID: nil, albumArtURL: nil, durationMilliseconds: 60_000, positionMilliseconds: 0, uri: "spotify:track:t"),
            isPaused: false,
            nextTracks: []
        ))
        let queue = QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api), playbackSession: playback, pollIntervalNanoseconds: 60_000_000_000, pollJitterFraction: 0)
        queue.isPanelVisible = true

        let inFlight = Task { await queue.refreshQueue() }
        await api.fetchQueueSignal.wait()
        // Runs once the main actor is free, which is after the joined refresh
        // below has registered and suspended.
        let release = Task { @MainActor in gate.signal() }
        await queue.refreshQueue()
        let fetchesWhenJoinedRefreshReturned = api.actions.filter { $0 == "fetchQueue" }.count
        await inFlight.value
        await release.value

        XCTAssertEqual(fetchesWhenJoinedRefreshReturned, 2, "A joined refresh returns after its own follow-up fetch, not before.")
        XCTAssertFalse(api.concurrentFetchDetected)
    }

    func testQueueRefreshShortCircuitsDuringRateLimitCooldown() async {
        let api = QueueTestPlaybackAPI()
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: StubWebPlaybackCommander()))
        playback.handle(.ready(deviceID: "device-1"))
        playback.handle(.stateChanged(
            PlaybackNowPlaying(name: "T", artists: ["A"], albumName: nil, albumID: nil, albumArtURL: nil, durationMilliseconds: 60_000, positionMilliseconds: 0, uri: "spotify:track:t"),
            isPaused: false,
            nextTracks: []
        ))
        // The cooldown runs on a clock the test steps, so a slow machine can't end it early.
        let clock = ManualPlaybackClock()
        let queue = QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api), playbackSession: playback, pollJitterFraction: 0, defaultRateLimitCooldownSeconds: 0.3, clock: clock)
        queue.setPanelVisible(true)

        api.errorToThrow = SpotifyAPIError.rateLimited(retryAfter: 0.3)
        await queue.refreshQueue()
        let fetchesAfterFirstFailure = api.actions.filter { $0 == "fetchQueue" }.count

        await queue.refreshQueue()
        let fetchesAfterSecondAttempt = api.actions.filter { $0 == "fetchQueue" }.count

        XCTAssertEqual(fetchesAfterFirstFailure, 1)
        XCTAssertEqual(fetchesAfterSecondAttempt, 1, "Manual refresh should yield to cooldown instead of calling Spotify again immediately.")
        XCTAssertEqual(queue.lastError?.title, "Rate limited")

        // The wait is at least a second, whatever Spotify asked for.
        clock.advance(by: .milliseconds(999))
        await queue.refreshQueue()
        XCTAssertEqual(api.actions.filter { $0 == "fetchQueue" }.count, 1, "The cooldown should hold until its last moment.")

        clock.advance(by: .milliseconds(1))
        await queue.refreshQueue()
        XCTAssertEqual(api.actions.filter { $0 == "fetchQueue" }.count, 2, "Once the cooldown ends, a refresh should ask Spotify again.")
    }

    func testQueuePollingStopsWhenAppBecomesInactive() async {
        let api = QueueTestPlaybackAPI()
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: StubWebPlaybackCommander()))
        playback.handle(.ready(deviceID: "device-1"))
        playback.handle(.stateChanged(
            PlaybackNowPlaying(name: "T", artists: ["A"], albumName: nil, albumID: nil, albumArtURL: nil, durationMilliseconds: 60_000, positionMilliseconds: 0, uri: "spotify:track:t"),
            isPaused: false,
            nextTracks: []
        ))
        let queue = QueueViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api),
            playbackSession: playback,
            pollIntervalNanoseconds: 30_000_000,
            pausedPollIntervalNanoseconds: 30_000_000,
            pollJitterFraction: 0
        )
        queue.isPanelVisible = true
        await queue.refreshQueue()
        let pollFetchStarted = AsyncSignal()
        api.onFetchQueue = {
            pollFetchStarted.signal()
        }
        queue.restartPollingIfNeeded()
        let didStartPollFetch = await pollFetchStarted.wait(timeout: .seconds(30))
        XCTAssertTrue(
            didStartPollFetch,
            "active queue polling should issue a fetch"
        )
        let fetchesBeforeInactive = api.actions.filter { $0 == "fetchQueue" }.count

        let pollTask = queue.pollTask
        queue.setAppActive(false)
        await pollTask?.value
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
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: StubWebPlaybackCommander()))
        playback.handle(.ready(deviceID: "device-1"))
        // `.ready` schedules a transport sync that can mark the device as
        // already transferred. Whether it wins the race against the play below
        // is scheduler-dependent, and it decided this test on CI once. State
        // the precondition instead: nothing has been transferred yet, so
        // playing must transfer first and then play.
        await Task.yield()
        playback.hasTransferredPlaybackToCurrentDevice = false
        let queue = QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api), playbackSession: playback)
        let item = QueueItem.from(track: MusicTrack(
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
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: StubWebPlaybackCommander()))
        let queue = QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api), playbackSession: playback)

        await queue.addToQueue(uri: "spotify:track:x")

        XCTAssertEqual(queue.lastError?.title, "Playback unavailable")
        XCTAssertFalse(api.actions.contains(where: { $0.hasPrefix("addToQueue:") }))
    }

    func testQueuePrefetchForLyricsAllowsHiddenPanelFetch() async {
        let api = QueueTestPlaybackAPI()
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: StubWebPlaybackCommander()))
        playback.handle(.ready(deviceID: "device-1"))
        playback.handle(.stateChanged(
            PlaybackNowPlaying(name: "T", artists: [], albumName: nil, albumID: nil, albumArtURL: nil, durationMilliseconds: 60_000, positionMilliseconds: 0, uri: "spotify:track:t"),
            isPaused: false,
            nextTracks: []
        ))
        let queue = QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api), playbackSession: playback)
        queue.setPanelVisible(false)

        await queue.prefetchQueueForLyricsOverlay()

        XCTAssertTrue(api.actions.contains("fetchQueue"))
    }

    /// #549: the optimistic shuffle windows ran on the wall clock (the queue's 40 ms here, the
    /// player's 2 s pending shuffle), so on a busy machine one ran out before `toggleShuffle()`
    /// returned and the old order came back. Both now run on a clock the test steps: a slow
    /// Spotify read (the stub's delay stands in for a loaded machine) doesn't move them, only
    /// stepping the clock past the timeout does.
    func testQueueOptimisticReconcileClearsAfterTimeout() async {
        let api = QueueTestPlaybackAPI()
        let clock = ManualPlaybackClock()
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: StubWebPlaybackCommander()), clock: clock, postShuffleSyncDelay: .seconds(10))
        playback.handle(.ready(deviceID: "device-1"))
        let timeout = Duration.milliseconds(40)
        let queue = QueueViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api),
            playbackSession: playback,
            optimisticReconcileTimeout: timeout,
            clock: clock
        )

        let one = MusicTrack(id: "1", name: "One", artists: ["A"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:1")
        let two = MusicTrack(id: "2", name: "Two", artists: ["B"], albumArtworkURL: nil, durationMilliseconds: 100_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:2")
        api.queueResponse = MusicPlaybackQueue(queue: [.track(one), .track(two)])
        queue.setPanelVisible(true)
        await queue.refreshQueue()
        let original = queue.upcomingItems.map(\.id)

        // The window runs on the test's clock, so however long the reads take in real time,
        // only the clock's own steps below can end it.
        await queue.toggleShuffle()
        let optimistic = queue.upcomingItems.map(\.id)
        XCTAssertNotEqual(optimistic, original, "A slow read must not end the optimistic shuffle early.")

        clock.advance(by: timeout - .milliseconds(1))
        await queue.refreshQueue()
        XCTAssertEqual(queue.upcomingItems.map(\.id), optimistic, "The optimistic order should hold until the timeout.")

        clock.advance(by: .milliseconds(1))
        await queue.refreshQueue()
        XCTAssertEqual(queue.upcomingItems.map(\.id), original, "Optimistic projection should clear after reconcile timeout.")
    }

    func testQueueRefreshMapsUnauthorizedAPIError() async {
        let api = QueueTestPlaybackAPI()
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: StubWebPlaybackCommander()))
        playback.handle(.ready(deviceID: "device-1"))
        playback.handle(.stateChanged(
            PlaybackNowPlaying(name: "T", artists: [], albumName: nil, albumID: nil, albumArtURL: nil, durationMilliseconds: 60_000, positionMilliseconds: 0, uri: "spotify:track:t"),
            isPaused: false,
            nextTracks: []
        ))
        let queue = QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api), playbackSession: playback)
        queue.setPanelVisible(true)
        api.errorToThrow = SpotifyAPIError.unauthorized

        await queue.refreshQueue()

        XCTAssertEqual(queue.lastError?.title, "Sign in again")
    }

    func testCancelledQueuePollDoesNotRefreshImmediately() async {
        let api = QueueTestPlaybackAPI()
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: StubWebPlaybackCommander()))
        playback.handle(.ready(deviceID: "device-1"))
        playback.handle(.stateChanged(
            PlaybackNowPlaying(name: "T", artists: ["A"], albumName: nil, albumID: nil, albumArtURL: nil, durationMilliseconds: 60_000, positionMilliseconds: 0, uri: "spotify:track:t"),
            isPaused: false,
            nextTracks: []
        ))
        let queue = QueueViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api),
            playbackSession: playback,
            pollIntervalNanoseconds: 60_000_000_000,
            pollJitterFraction: 0
        )
        queue.isPanelVisible = true
        await queue.refreshQueue()
        queue.restartPollingIfNeeded()
        let pollTask = queue.pollTask
        XCTAssertNotNil(pollTask)
        let baselineFetchCount = api.actions.filter { $0 == "fetchQueue" }.count
        XCTAssertEqual(baselineFetchCount, 1)

        queue.setPanelVisible(false)
        // Let the cancelled poll loop run to its end, so a fetch it issued
        // after waking from the cancelled sleep would be counted below.
        await pollTask?.value

        let fetchCountAfterCancel = api.actions.filter { $0 == "fetchQueue" }.count
        XCTAssertEqual(
            fetchCountAfterCancel,
            baselineFetchCount,
            "Cancelling the queue poll task during sleep must not trigger an immediate GET /v1/me/player/queue."
        )
    }

    /// #470: with Deutsch picked, a queue refresh that couldn't reach Spotify showed the German
    /// title over URLSession's English "Could not connect to the server.", because that text
    /// follows the Mac's language. The sentence must follow the app's language, in each language.
    func testQueueNetworkErrorFollowsTheAppLanguage() async throws {
        let expected: [(AppLanguage, String)] = [
            (.english, "Could not connect to Spotify. Check your network, then try again."),
            (.german, "Verbindung zu Spotify fehlgeschlagen. Prüfe dein Netzwerk und versuche es erneut."),
            (.spanish, "No se pudo conectar con Spotify. Comprueba tu red e inténtalo de nuevo.")
        ]
        // What URLSession hands back on an English Mac, word for word.
        let systemText = "Could not connect to the server."
        // SpotifyPlaybackAPI lets URLSession's error through unchanged.
        let failures: [Error] = [
            URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: systemText]),
            URLError(.networkConnectionLost, userInfo: [NSLocalizedDescriptionKey: "The network connection was lost."])
        ]
        for (language, message) in expected {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("queue-network-\(UUID().uuidString).json")
            let store = SpotiglassSettingsStore(fileURL: url)
            try store.mutate { $0.appearance.language = language }
            SpotiglassL10n.settingsStore = store
            defer { SpotiglassL10n.settingsStore = nil }

            for failure in failures {
                let api = QueueTestPlaybackAPI()
                let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: StubWebPlaybackCommander()))
                playback.handle(.ready(deviceID: "device-1"))
                let queue = QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api), playbackSession: playback)
                queue.setPanelVisible(true)
                api.errorToThrow = failure

                await queue.refreshQueue()

                let banner = try XCTUnwrap(queue.lastError, "\(language) \(failure)")
                XCTAssertEqual(banner.title, SpotiglassL10n.string("error.queue.updateFailed.title"))
                XCTAssertEqual(banner.message, message, "\(language) \(failure)")
                XCTAssertNil(banner.message.range(of: "server."), "\(language) \(failure)")
                XCTAssertNil(banner.message.range(of: "was lost"), "\(language) \(failure)")
            }
        }
    }
}


extension QueuePanelTests {
    /// #470: SpotifyPlaybackAPI decodes the queue itself, so a body it can't read threw a bare
    /// DecodingError whose text ("The data couldn't be read ...") follows the Mac's language.
    func testUnreadableQueueResponseFollowsTheAppLanguage() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-decoding-\(UUID().uuidString).json")
        let store = SpotiglassSettingsStore(fileURL: url)
        try store.mutate { $0.appearance.language = .german }
        SpotiglassL10n.settingsStore = store
        defer { SpotiglassL10n.settingsStore = nil }

        let api = SpotifyPlaybackAPI(
            baseURL: URL(string: "https://api.spotify.com")!,
            tokenProvider: QueueTestTokenProvider(),
            httpClient: UnreadableQueueHTTPClient()
        )
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: StubWebPlaybackCommander()))
        playback.handle(.ready(deviceID: "device-1"))
        let queue = QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api), playbackSession: playback)
        queue.setPanelVisible(true)

        await queue.refreshQueue()

        let banner = try XCTUnwrap(queue.lastError)
        XCTAssertEqual(banner.title, "Warteschlangen-Update fehlgeschlagen")
        XCTAssertEqual(banner.message, "Spotify hat Daten zurückgegeben, die Spotiglass nicht lesen konnte. Versuchen Sie zu aktualisieren.")
    }
}

@MainActor
private final class QueueTestTokenProvider: PlaybackAccessTokenProviding {
    func playbackAccessToken() async throws -> String { "token" }
    func refreshedPlaybackAccessToken() async throws -> String { "token" }
}

extension QueuePanelTests {
    /// #470: a 403 without Spotify's own text showed a hard-coded English Premium sentence.
    func testPremiumRefusalWithoutSpotifyTextFollowsTheAppLanguage() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-forbidden-\(UUID().uuidString).json")
        let store = SpotiglassSettingsStore(fileURL: url)
        try store.mutate { $0.appearance.language = .german }
        SpotiglassL10n.settingsStore = store
        defer { SpotiglassL10n.settingsStore = nil }

        let api = SpotifyPlaybackAPI(
            baseURL: URL(string: "https://api.spotify.com")!,
            tokenProvider: QueueTestTokenProvider(),
            httpClient: ForbiddenQueueHTTPClient()
        )
        do {
            _ = try await api.fetchQueue()
            XCTFail("Expected a refusal")
        } catch {
            XCTAssertEqual(QueueViewModel.displayError(for: error)?.message, "Spotify hat den Zugriff verweigert.")
            XCTAssertEqual(
                PlaybackSessionViewModel.displayError(for: error).message,
                "Zum Abspielen von Musik in Spotiglass ist Spotify Premium erforderlich."
            )
        }
    }
}

private final class ForbiddenQueueHTTPClient: HTTPClient, @unchecked Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (Data(), HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
    }
}

private final class UnreadableQueueHTTPClient: HTTPClient, @unchecked Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        return (Data(#"{"queue":"invalid"}"#.utf8), response)
    }
}

private final class StubWebPlaybackCommander: WebPlaybackCommanding {
    func loadHost(generation: PlaybackHostGeneration) {}

    func send(_ command: PlaybackBridgeCommand, payload: [String: Any]) async throws {}
}

private final class QueueTestPlaybackAPI: SpotifyPlaybackControlling {
    // Playback calls run on background threads while tests read and set this
    // mock on the main thread, so every field lives in `state` behind `lock`.
    // An unlocked read of the call log raced a background `fetchPlayerSnapshot`
    // append and once saw an empty log in CI (#379).
    private struct State {
        var actions: [String] = []
        var onFetchQueue: (() -> Void)?
        var fetchQueueGate: AsyncSignal?
        var queueResponse = MusicPlaybackQueue(queue: [])
        var queueResponses: [MusicPlaybackQueue] = []
        var errorToThrow: Error?
        var setShuffleError: Error?
        var setRepeatError: Error?
        var fetchQueueHold: MockCallHold?
        var addToQueueHold: MockCallHold?
        var addToQueueErrors: [Error?] = []
        var concurrentFetchDetected = false
        var maxConcurrentFetches = 0
        var currentConcurrentFetches = 0
        var reportedTransport = MusicPlaybackTransport(shuffle: false, repeatMode: .off)
    }

    private let lock = NSLock()
    private var state = State()
    let fetchQueueSignal = AsyncSignal()

    var actions: [String] { locked { $0.actions } }
    var concurrentFetchDetected: Bool { locked { $0.concurrentFetchDetected } }
    var maxConcurrentFetches: Int { locked { $0.maxConcurrentFetches } }
    var onFetchQueue: (() -> Void)? {
        get { locked { $0.onFetchQueue } }
        set { locked { $0.onFetchQueue = newValue } }
    }
    /// When set, `fetchQueue` waits for this signal after it is recorded, so a
    /// test can hold a fetch in flight without a timing window.
    var fetchQueueGate: AsyncSignal? {
        get { locked { $0.fetchQueueGate } }
        set { locked { $0.fetchQueueGate = newValue } }
    }
    var queueResponse: MusicPlaybackQueue {
        get { locked { $0.queueResponse } }
        set { locked { $0.queueResponse = newValue } }
    }
    var queueResponses: [MusicPlaybackQueue] {
        get { locked { $0.queueResponses } }
        set { locked { $0.queueResponses = newValue } }
    }
    var errorToThrow: Error? {
        get { locked { $0.errorToThrow } }
        set { locked { $0.errorToThrow = newValue } }
    }
    var setShuffleError: Error? {
        get { locked { $0.setShuffleError } }
        set { locked { $0.setShuffleError = newValue } }
    }
    var setRepeatError: Error? {
        get { locked { $0.setRepeatError } }
        set { locked { $0.setRepeatError = newValue } }
    }
    /// Holds `fetchQueue` after it is recorded and `fetchQueueGate` opened, while it still
    /// counts as in flight.
    var fetchQueueHold: MockCallHold? {
        get { locked { $0.fetchQueueHold } }
        set { locked { $0.fetchQueueHold = newValue } }
    }
    /// Holds `addToQueue` after it is recorded.
    var addToQueueHold: MockCallHold? {
        get { locked { $0.addToQueueHold } }
        set { locked { $0.addToQueueHold = newValue } }
    }
    var addToQueueErrors: [Error?] {
        get { locked { $0.addToQueueErrors } }
        set { locked { $0.addToQueueErrors = newValue } }
    }

    func transferPlayback(to deviceID: String, play: Bool) async throws {
        appendAction("transfer:\(deviceID):\(play)")
    }

    func play(uri: String, deviceID: String) async throws {
        appendAction("play:\(deviceID):\(uri)")
    }

    func play(contextURI: String, deviceID: String) async throws {
        appendAction("play-context:\(deviceID):\(contextURI)")
    }

    func pause(deviceID: String) async throws {
        appendAction("pause:\(deviceID)")
    }

    func resume(deviceID: String) async throws {
        appendAction("resume:\(deviceID)")
    }

    func play(uris: [String], deviceID: String) async throws {
        appendAction("play-list:\(deviceID):\(uris.joined(separator: ","))")
    }

    func play(uris: [String], offsetURI: String, deviceID: String) async throws {
        appendAction("play-list:\(deviceID):\(uris.joined(separator: ","))")
    }

    func seek(to milliseconds: Int, deviceID: String) async throws {}

    func next(deviceID: String) async throws {}

    func previous(deviceID: String) async throws {}

    func fetchQueue() async throws -> MusicPlaybackQueue {
        let (onFetchQueue, gate, hold) = locked { state -> ((() -> Void)?, AsyncSignal?, MockCallHold?) in
            state.actions.append("fetchQueue")
            state.currentConcurrentFetches += 1
            state.maxConcurrentFetches = max(state.maxConcurrentFetches, state.currentConcurrentFetches)
            if state.currentConcurrentFetches > 1 {
                state.concurrentFetchDetected = true
            }
            return (state.onFetchQueue, state.fetchQueueGate, state.fetchQueueHold)
        }
        defer { locked { $0.currentConcurrentFetches -= 1 } }
        fetchQueueSignal.signal()
        onFetchQueue?()
        await gate?.wait()
        await hold?.pass()
        return try locked { state -> MusicPlaybackQueue in
            if let errorToThrow = state.errorToThrow {
                throw errorToThrow
            }
            if !state.queueResponses.isEmpty {
                return state.queueResponses.removeFirst()
            }
            return state.queueResponse
        }
    }

    func addToQueue(uri: String, deviceID: String) async throws {
        // Track attempted submissions so ambiguous transport failures are visible in tests.
        appendAction("addToQueue:\(deviceID):\(uri)")
        await locked { $0.addToQueueHold }?.pass()
        let error = locked { state -> Error? in
            state.addToQueueErrors.isEmpty ? nil : state.addToQueueErrors.removeFirst()
        }
        if let error {
            throw error
        }
    }

    func fetchPlayerSnapshot() async throws -> MusicPlaybackSnapshot? {
        appendAction("fetchPlayerSnapshot")
        return MusicPlaybackSnapshot(transport: locked { $0.reportedTransport }, activeDevice: nil, isPlaying: true)
    }

    func fetchAvailableDevices() async throws -> [MusicPlaybackDevice] {
        appendAction("fetchAvailableDevices")
        return []
    }

    func setShuffle(enabled: Bool, deviceID: String) async throws {
        if let setShuffleError { throw setShuffleError }
        locked { state in
            state.actions.append("setShuffle:\(deviceID):\(enabled)")
            state.reportedTransport = MusicPlaybackTransport(shuffle: enabled, repeatMode: state.reportedTransport.repeatMode)
        }
    }

    func setRepeat(mode: MusicRepeatMode, deviceID: String) async throws {
        if let setRepeatError { throw setRepeatError }
        locked { state in
            state.actions.append("setRepeat:\(deviceID):\(mode.rawValue)")
            state.reportedTransport = MusicPlaybackTransport(shuffle: state.reportedTransport.shuffle, repeatMode: mode)
        }
    }

    private func locked<T>(_ body: (inout State) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }

    private func appendAction(_ action: String) {
        locked { $0.actions.append(action) }
    }
}
