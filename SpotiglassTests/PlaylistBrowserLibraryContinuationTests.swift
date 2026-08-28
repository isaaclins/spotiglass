import XCTest

@testable import Spotiglass

@MainActor
final class PlaylistBrowserLibraryContinuationTests: XCTestCase {
    private func track(
        _ id: String,
        artistID: String,
        playable: Bool? = true
    ) -> SpotifyTrack {
        SpotifyTrack(
            id: id,
            name: "Track \(id)",
            artists: ["Artist \(artistID)"],
            artistRefs: [SpotifyArtistRef(id: artistID, name: "Artist \(artistID)")],
            albumArtworkURL: nil,
            durationMilliseconds: 180_000,
            isExplicit: false,
            isPlayable: playable,
            linkedFromID: nil,
            uri: "spotify:track:\(id)"
        )
    }

    private func item(_ track: SpotifyTrack) -> SpotifyPlaylistTrackItem {
        SpotifyPlaylistTrackItem(id: track.id, content: .track(track))
    }

    private func row(_ track: SpotifyTrack) -> TrackRowViewModel {
        TrackRowViewModel(topTrack: track, listPosition: 1)
    }

    private func makeViewModel(
        api: MockBrowsingAPI,
        cache: MockBrowsingCache,
        playlist: SpotifyPlaylistSummary? = nil
    ) -> PlaylistBrowserViewModel {
        let viewModel = PlaylistBrowserViewModel(api: api, cache: cache)
        if let playlist {
            viewModel.playlistsByID = [playlist.id: playlist]
            viewModel.playlistState = .loaded([PlaylistRowViewModel(playlist)])
        }
        return viewModel
    }

    func testCollectionUsesPerPlaylistAndLikedSongsCachesBeforeCrawlingThoseEndpoints() async {
        let seed = track("seed", artistID: "artist")
        let continuation = track("continuation", artistID: "artist")
        let playlist = PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "P1")
        let cache = MockBrowsingCache(
            cachedPlaylists: [playlist],
            cachedTracks: [playlist.id: [item(seed), item(continuation)]]
        )
        cache.cachedTracks[SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID] = [item(seed)]
        let api = MockBrowsingAPI(playlistResults: [], trackResults: [:])
        let viewModel = makeViewModel(api: api, cache: cache, playlist: playlist)
        var queuedURIs: [String] = []

        await viewModel.enqueueLibraryContinuation(from: row(seed)) { uris in
            queuedURIs = uris
            return QueueEnqueueResult(requested: uris.count, enqueued: uris.count)
        }

        XCTAssertEqual(queuedURIs, [continuation.uri])
        XCTAssertEqual(api.savedTracksCallCount, 0)
        XCTAssertTrue(api.playlistTracksInvocationCountByID.isEmpty)
        XCTAssertNotNil(cache.savedLibraryContinuation)
    }

    func testCollectionFetchesPlaylistListWhenBrowserHasNotLoadedIt() async {
        let seed = track("seed", artistID: "artist")
        let continuation = track("continuation", artistID: "artist")
        let playlist = PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "P1")
        let api = MockBrowsingAPI(
            playlistResults: [.success([playlist])],
            trackResults: [playlist.id: [.success([item(seed), item(continuation)])]],
            savedTracksResult: .success(
                SpotifySavedTracksResult(tracks: [], totalAvailable: 0)
            )
        )
        let viewModel = makeViewModel(api: api, cache: MockBrowsingCache())
        var queued: [String] = []

        await viewModel.enqueueLibraryContinuation(from: row(seed)) { uris in
            queued = uris
            return QueueEnqueueResult(requested: uris.count, enqueued: uris.count)
        }

        XCTAssertEqual(queued, [continuation.uri])
        XCTAssertEqual(api.currentUserPlaylistsCallCount, 1)
        XCTAssertEqual(api.playlistTracksInvocationCountByID[playlist.id], 1)
    }

    func testArtistTopTrackCollectionQueriesEveryCreditedArtist() async {
        let seed = SpotifyTrack(
            id: "seed",
            name: "Track seed",
            artists: ["Artist a", "Artist b"],
            artistRefs: [
                SpotifyArtistRef(id: "artist-a", name: "Artist a"),
                SpotifyArtistRef(id: "artist-b", name: "Artist b")
            ],
            albumArtworkURL: nil,
            durationMilliseconds: 180_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "spotify:track:seed"
        )
        let api = MockBrowsingAPI(
            playlistResults: [],
            trackResults: [:],
            savedTracksResult: .success(
                SpotifySavedTracksResult(tracks: [item(seed)], totalAvailable: 1)
            )
        )
        let cache = MockBrowsingCache()
        let viewModel = makeViewModel(api: api, cache: cache)

        await viewModel.enqueueLibraryContinuation(from: row(seed)) { uris in
            XCTAssertTrue(uris.isEmpty)
            return QueueEnqueueResult(requested: 0, enqueued: 0)
        }

        XCTAssertEqual(api.artistTopTracksRequestedIDs, ["artist-a", "artist-b"])
    }

    func testCancelledCollectionDoesNotEnqueueOrPersist() async {
        let seed = track("seed", artistID: "artist")
        let api = MockBrowsingAPI(playlistResults: [], trackResults: [:])
        let cache = MockBrowsingCache()
        let viewModel = makeViewModel(api: api, cache: cache)
        var didEnqueue = false

        let operation = Task { @MainActor in
            await viewModel.enqueueLibraryContinuation(from: row(seed)) { _ in
                didEnqueue = true
                return QueueEnqueueResult(requested: 0, enqueued: 0)
            }
        }
        operation.cancel()
        await operation.value

        XCTAssertFalse(didEnqueue)
        XCTAssertNil(cache.savedLibraryContinuation)
        XCTAssertNil(viewModel.trackMutationToast)
    }

    func testCollectionFetchesOnlyMissingSourcesAndPersistsTheAggregateIndex() async {
        let seed = track("seed", artistID: "artist")
        let sameArtist = track("same", artistID: "artist")
        let other = track("other", artistID: "other")
        let first = PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "P1")
        let second = PlaylistBrowsingTestFixtures.playlist(id: "p2", name: "P2")
        let api = MockBrowsingAPI(
            playlistResults: [],
            trackResults: [
                first.id: [.success([item(seed), item(sameArtist)])],
                second.id: [.success([item(other)])],
            ],
            savedTracksResult: .success(
                SpotifySavedTracksResult(tracks: [item(seed), item(other)], totalAvailable: 2)
            )
        )
        api.topTracksHandler = { _, _ in [other] }
        api.topArtistsHandler = { _, _ in
            [SpotifyArtist(id: "other", name: "Artist other", imageURL: nil, uri: "spotify:artist:other")]
        }
        api.followedArtistsHandler = { _, _ in
            [SpotifyArtist(id: "artist", name: "Artist artist", imageURL: nil, uri: "spotify:artist:artist")]
        }
        api.artistTopTracksHandler = { _, _ in [sameArtist] }
        let cache = MockBrowsingCache()
        let viewModel = makeViewModel(api: api, cache: cache, playlist: first)
        viewModel.playlistsByID[second.id] = second
        viewModel.playlistState = .loaded([PlaylistRowViewModel(first)])
        var queued: [String] = []

        await viewModel.enqueueLibraryContinuation(from: row(seed)) { uris in
            queued = uris
            return QueueEnqueueResult(requested: uris.count, enqueued: uris.count)
        }

        XCTAssertEqual(queued, [sameArtist.uri, other.uri])
        XCTAssertEqual(api.playlistTracksInvocationCountByID[first.id], 1)
        XCTAssertEqual(api.playlistTracksInvocationCountByID[second.id], 1)
        XCTAssertEqual(api.savedTracksCallCount, 1)
        XCTAssertEqual(api.topTracksCallCount, 1)
        XCTAssertEqual(api.topArtistsCallCount, 1)
        XCTAssertEqual(api.followedArtistsCallCount, 1)
        XCTAssertEqual(api.artistTopTracksCallCount, 1)
        XCTAssertNotNil(cache.savedLibraryContinuation)
    }

    func testCollectionFallsBackToDetailRowsAndReportsWhenAllNetworkSourcesFail() async {
        struct SampleError: Error {}
        let seed = track("seed", artistID: "artist")
        let playlist = PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "P1")
        let api = MockBrowsingAPI(
            playlistResults: [],
            trackResults: [playlist.id: [.failure(SampleError())]],
            savedTracksResult: .failure(SampleError())
        )
        api.topTracksHandler = { _, _ in throw SampleError() }
        api.topArtistsHandler = { _, _ in throw SampleError() }
        api.followedArtistsHandler = { _, _ in throw SampleError() }
        api.artistTopTracksHandler = { _, _ in throw SampleError() }
        let cache = MockBrowsingCache()
        let viewModel = makeViewModel(api: api, cache: cache, playlist: playlist)
        var didEnqueue = false

        await viewModel.enqueueLibraryContinuation(from: row(seed)) { _ in
            didEnqueue = true
            return QueueEnqueueResult(requested: 0, enqueued: 0)
        }

        XCTAssertFalse(didEnqueue)
        XCTAssertEqual(viewModel.trackMutationToast, SpotiglassL10n.string("library.continuation.empty"))
        XCTAssertEqual(api.playlistTracksInvocationCountByID[playlist.id], 1)
    }

    func testCollectionUsesLoadedDetailRowsWhenItsPlaylistCacheIsMissing() async {
        let seed = track("seed", artistID: "artist")
        let playlist = PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "P1")
        let api = MockBrowsingAPI(playlistResults: [], trackResults: [:])
        let viewModel = makeViewModel(api: api, cache: MockBrowsingCache(), playlist: playlist)
        viewModel.detailState = .loaded(
            .playlist(
                PlaylistDetailViewModel(
                    playlist: PlaylistRowViewModel(playlist),
                    tracks: TrackRowViewModel.numberedTopTracks([seed])
                )
            )
        )

        await viewModel.enqueueLibraryContinuation(from: row(seed)) { uris in
            XCTAssertTrue(uris.isEmpty)
            return QueueEnqueueResult(requested: uris.count, enqueued: uris.count)
        }

        XCTAssertNil(api.playlistTracksInvocationCountByID[playlist.id])
        XCTAssertEqual(viewModel.trackMutationToast, SpotiglassL10n.string("library.continuation.empty"))
    }

    func testContinuationReportsQueueFailureAndPartialEnqueue() async {
        let seed = track("seed", artistID: "artist")
        let matches = [
            track("one", artistID: "artist"), track("two", artistID: "artist"), track("three", artistID: "artist"),
        ]
        let cache = MockBrowsingCache()
        cache.cachedLibraryContinuation = LibraryContinuationLibrary(savedTracks: [seed] + matches)
        let api = MockBrowsingAPI(playlistResults: [], trackResults: [:])
        let viewModel = makeViewModel(api: api, cache: cache)

        await viewModel.enqueueLibraryContinuation(from: row(seed)) { uris in
            QueueEnqueueResult(requested: uris.count, enqueued: 0)
        }
        XCTAssertEqual(viewModel.trackMutationToast, SpotiglassL10n.string("library.continuation.queueFailed"))

        await viewModel.enqueueLibraryContinuation(from: row(seed)) { uris in
            QueueEnqueueResult(requested: uris.count, enqueued: 1)
        }
        XCTAssertEqual(
            viewModel.trackMutationToast,
            SpotiglassL10n.format("library.continuation.partial", Int64(1), Int64(3))
        )
    }

    func testFreshAggregateIndexAvoidsAllSourceRequestsOnRepeatedContinuation() async {
        let seed = track("seed", artistID: "artist")
        let continuation = track("continuation", artistID: "artist")
        let cache = MockBrowsingCache()
        let api = MockBrowsingAPI(playlistResults: [], trackResults: [:])
        let viewModel = makeViewModel(api: api, cache: cache)
        cache.cachedLibraryContinuation = LibraryContinuationLibrary(
            savedTracks: [seed, continuation]
        )
        var invocationCount = 0

        await viewModel.enqueueLibraryContinuation(from: row(seed)) { uris in
            invocationCount += 1
            XCTAssertEqual(uris, [continuation.uri])
            return QueueEnqueueResult(requested: uris.count, enqueued: uris.count)
        }
        await viewModel.enqueueLibraryContinuation(from: row(seed)) { uris in
            invocationCount += 1
            XCTAssertEqual(uris, [continuation.uri])
            return QueueEnqueueResult(requested: uris.count, enqueued: uris.count)
        }

        XCTAssertEqual(invocationCount, 2)
        XCTAssertEqual(api.savedTracksCallCount, 0)
        XCTAssertEqual(api.topArtistsCallCount, 0)
        XCTAssertEqual(api.followedArtistsCallCount, 0)
        XCTAssertEqual(api.artistTopTracksCallCount, 0)
    }

    func testSmallLibraryIsQueuedWithoutPaddingAndReportsThatItIsShort() async {
        let seed = track("seed", artistID: "artist")
        let onlyMatch = track("match", artistID: "artist")
        let cache = MockBrowsingCache()
        cache.cachedLibraryContinuation = LibraryContinuationLibrary(savedTracks: [seed, onlyMatch])
        let api = MockBrowsingAPI(playlistResults: [], trackResults: [:])
        let viewModel = makeViewModel(api: api, cache: cache)
        var queued: [String] = []

        await viewModel.enqueueLibraryContinuation(from: row(seed)) { uris in
            queued = uris
            return QueueEnqueueResult(requested: uris.count, enqueued: uris.count)
        }

        XCTAssertEqual(queued, [onlyMatch.uri])
        XCTAssertEqual(
            viewModel.trackMutationToast,
            SpotiglassL10n.format("library.continuation.short", Int64(1))
        )
    }

    func testEmptyLibraryReportsAVisibleLocalizedMessageAndDoesNotCallQueue() async {
        let seed = track("seed", artistID: "artist")
        let cache = MockBrowsingCache()
        cache.cachedLibraryContinuation = LibraryContinuationLibrary(savedTracks: [seed])
        let api = MockBrowsingAPI(playlistResults: [], trackResults: [:])
        let viewModel = makeViewModel(api: api, cache: cache)
        var didEnqueue = false

        await viewModel.enqueueLibraryContinuation(from: row(seed)) { _ in
            didEnqueue = true
            return QueueEnqueueResult(requested: 0, enqueued: 0)
        }

        XCTAssertFalse(didEnqueue)
        XCTAssertEqual(
            viewModel.trackMutationToast,
            SpotiglassL10n.string("library.continuation.empty")
        )
    }

    func testNonTrackMenuTargetReportsWhyContinuationCannotStart() async {
        let episode = SpotifyEpisode(
            id: "episode",
            name: "Episode",
            showName: "Show",
            artworkURL: nil,
            durationMilliseconds: 1_000,
            isPlayable: true,
            uri: "spotify:episode:episode"
        )
        let target = TrackRowViewModel(
            SpotifyPlaylistTrackItem(id: "episode", content: .episode(episode)),
            listPosition: 1
        )
        let viewModel = makeViewModel(
            api: MockBrowsingAPI(playlistResults: [], trackResults: [:]),
            cache: MockBrowsingCache()
        )

        await viewModel.enqueueLibraryContinuation(from: target) { _ in
            XCTFail("Episodes must not enter the continuation queue")
            return QueueEnqueueResult(requested: 0, enqueued: 0)
        }

        XCTAssertEqual(
            viewModel.trackMutationToast,
            SpotiglassL10n.string("library.continuation.unavailable")
        )
    }
}
