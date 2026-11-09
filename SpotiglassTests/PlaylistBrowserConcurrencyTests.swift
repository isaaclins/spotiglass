import XCTest
@testable import Spotiglass

@MainActor
final class PlaylistBrowserConcurrencyTests: XCTestCase {

    func testConcurrentSelectArtistCoalescesSingleNetworkChain() async {
        let page1 = MusicArtistAlbum(
            id: "alb-1", name: "First", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album, uri: "spotify:album:alb-1"
        )
        let page2 = MusicArtistAlbum(
            id: "alb-2", name: "Second", imageURL: nil, releaseYear: "2023", totalTracks: 1, group: .album, uri: "spotify:album:alb-2"
        )
        let firstPageStarted = AsyncSignal()
        let releaseFirstPage = AsyncSignal()
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            artistAlbumsPageHandler: { _, _, _, offset, _ in
                if offset == 0 {
                    firstPageStarted.signal()
                    await releaseFirstPage.wait()
                }
                if offset == 0 {
                    return MusicArtistAlbumsPage(
                        items: [page1],
                        next: URL(string: "https://api.spotify.com/v1/artists/artist-xyz/albums?offset=10&limit=10")
                    )
                }
                return MusicArtistAlbumsPage(items: [page2], next: nil)
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        async let first: Void = viewModel.selectArtist(id: "artist-xyz")
        let didStartFirstPage = await firstPageStarted.wait(timeout: .seconds(1))
        XCTAssertTrue(didStartFirstPage, "the first artist load should be in flight before the duplicate")
        async let second: Void = viewModel.selectArtist(id: "artist-xyz")
        releaseFirstPage.signal()
        _ = await (first, second)

        XCTAssertEqual(api.artistAlbumsPageCallCount, 2, "Concurrent same-artist opens should share one in-flight artist load.")
    }

    func testSelectArtistWithinTTLUsesCachedSnapshotWithoutRefetch() async {
        var now = Date(timeIntervalSince1970: 1_000)
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            artistAlbumsPageHandler: { _, _, _, offset, _ in
                if offset == 0 {
                    return MusicArtistAlbumsPage(
                        items: [MusicArtistAlbum(id: "alb-1", name: "First", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album, uri: "spotify:album:alb-1")],
                        next: nil
                    )
                }
                return MusicArtistAlbumsPage(items: [], next: nil)
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache(), now: { now }, artistDetailCacheTTL: 120)

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")
        let firstCount = api.artistAlbumsPageCallCount
        now = now.addingTimeInterval(30)
        await viewModel.selectArtist(id: "artist-xyz")

        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(api.artistAlbumsPageCallCount, 1, "Reopening same artist within TTL should reuse cached snapshot.")
    }

    func testLateArtistLoadMoreSuccessCannotReplaceNewerArtistDetail() async {
        let firstPageURL = URL(string: "https://api.spotify.com/v1/artists/artist-a/albums?offset=10&limit=10")!
        let aLoadMoreGate = TestDeferred<Void>()
        let pageA1 = MusicArtistAlbum(
            id: "a-alb-1", name: "A First", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album, uri: "spotify:album:a-alb-1"
        )
        let pageA2 = MusicArtistAlbum(
            id: "a-alb-2", name: "A Second", imageURL: nil, releaseYear: "2023", totalTracks: 1, group: .album, uri: "spotify:album:a-alb-2"
        )
        let pageB1 = MusicArtistAlbum(
            id: "b-alb-1", name: "B First", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album, uri: "spotify:album:b-alb-1"
        )
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: [:],
            artistAlbumsPageHandler: { id, _, _, offset, _ in
                if id == "artist-a" {
                    if offset == 0 {
                        return MusicArtistAlbumsPage(items: [pageA1], next: firstPageURL)
                    }
                    await aLoadMoreGate.wait()
                    return MusicArtistAlbumsPage(items: [pageA2], next: nil)
                }
                return MusicArtistAlbumsPage(items: [pageB1], next: nil)
            }
        )
        let viewModel = PlaylistBrowserViewModel(
            api: api,
            cache: MockBrowsingCache(),
            initialArtistAlbumPageCount: 1
        )

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-a")
        let loadMoreTask = Task { await viewModel.loadMoreArtistAlbums() }
        await aLoadMoreGate.waitUntilBlocked()

        await viewModel.selectArtist(id: "artist-b")
        let bDetail = viewModel.detailState
        let bPaging = viewModel.currentArtistAlbumsPaging
        let bSnapshot = viewModel.cachedArtistSnapshots["artist-b"]
        let aSnapshot = viewModel.cachedArtistSnapshots["artist-a"]

        await aLoadMoreGate.resolve(())
        await loadMoreTask.value

        XCTAssertEqual(viewModel.detailState, bDetail)
        XCTAssertEqual(viewModel.currentArtistAlbumsPaging?.artistID, bPaging?.artistID)
        XCTAssertEqual(viewModel.currentArtistAlbumsPaging?.albums.map(\.id), bPaging?.albums.map(\.id))
        XCTAssertEqual(viewModel.cachedArtistSnapshots["artist-b"]?.snapshot.albums.map(\.id), bSnapshot?.snapshot.albums.map(\.id))
        XCTAssertEqual(viewModel.cachedArtistSnapshots["artist-a"]?.snapshot.albums.map(\.id), aSnapshot?.snapshot.albums.map(\.id))
    }

    func testLateArtistLoadMoreFailureCannotPublishStaleError() async {
        struct LoadMoreFailure: Error {}
        let firstPageURL = URL(string: "https://api.spotify.com/v1/artists/artist-a/albums?offset=10&limit=10")!
        let aLoadMoreGate = TestDeferred<Void>()
        let pageA1 = MusicArtistAlbum(
            id: "a-alb-1", name: "A First", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album, uri: "spotify:album:a-alb-1"
        )
        let pageB1 = MusicArtistAlbum(
            id: "b-alb-1", name: "B First", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album, uri: "spotify:album:b-alb-1"
        )
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: [:],
            artistAlbumsPageHandler: { id, _, _, offset, _ in
                if id == "artist-a" {
                    if offset == 0 {
                        return MusicArtistAlbumsPage(items: [pageA1], next: firstPageURL)
                    }
                    await aLoadMoreGate.wait()
                    throw LoadMoreFailure()
                }
                return MusicArtistAlbumsPage(items: [pageB1], next: nil)
            }
        )
        let viewModel = PlaylistBrowserViewModel(
            api: api,
            cache: MockBrowsingCache(),
            initialArtistAlbumPageCount: 1
        )

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-a")
        let loadMoreTask = Task { await viewModel.loadMoreArtistAlbums() }
        await aLoadMoreGate.waitUntilBlocked()

        await viewModel.selectArtist(id: "artist-b")
        let bDetail = viewModel.detailState
        let bPaging = viewModel.currentArtistAlbumsPaging
        let bSnapshot = viewModel.cachedArtistSnapshots["artist-b"]

        await aLoadMoreGate.resolve(())
        await loadMoreTask.value

        XCTAssertEqual(viewModel.detailState, bDetail)
        XCTAssertEqual(viewModel.currentArtistAlbumsPaging?.artistID, bPaging?.artistID)
        XCTAssertEqual(viewModel.currentArtistAlbumsPaging?.albums.map(\.id), bPaging?.albums.map(\.id))
        XCTAssertEqual(viewModel.cachedArtistSnapshots["artist-b"]?.snapshot.albums.map(\.id), bSnapshot?.snapshot.albums.map(\.id))
        if case .staleCache = viewModel.detailState {
            XCTFail("A late artist failure must not publish a stale-cache banner for artist B")
        }
        if case .error = viewModel.detailState {
            XCTFail("A late artist failure must not publish an error for artist B")
        }
    }

    func testLoadMoreArtistAlbumsClearsPagingLoadingWhenSameArtistBecomesRefreshing() async {
        let nextURL = URL(string: "https://api.spotify.com/v1/artists/artist-xyz/albums?offset=10&limit=10")!
        let loadMoreGate = TestDeferred<Void>()
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: [:],
            artistAlbumsPageHandler: { _, _, _, offset, _ in
                if offset == 0 {
                    return MusicArtistAlbumsPage(
                        items: [MusicArtistAlbum(id: "alb-1", name: "First", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album, uri: "spotify:album:alb-1")],
                        next: nextURL
                    )
                }
                await loadMoreGate.wait()
                return MusicArtistAlbumsPage(items: [], next: nil)
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache(), initialArtistAlbumPageCount: 1)

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")
        let loadMoreTask = Task { await viewModel.loadMoreArtistAlbums() }
        await loadMoreGate.waitUntilBlocked()

        guard case let .loaded(.artist(detail)) = viewModel.detailState else {
            return XCTFail("Expected loaded artist detail before refreshing it")
        }
        viewModel.detailState = .refreshing(.artist(detail))

        await loadMoreGate.resolve(())
        await loadMoreTask.value

        XCTAssertEqual(viewModel.currentArtistAlbumsPaging?.isLoading, false)
        if case .refreshing(.artist) = viewModel.detailState {
            XCTAssertTrue(true)
        } else {
            XCTFail("Pagination completion must not replace a same-artist refreshing surface")
        }
    }

    func testLoadMoreArtistAlbumsFetchesOneAdditionalPageOnDemand() async {
        let nextURL = URL(string: "https://api.spotify.com/v1/artists/artist-xyz/albums?offset=10&limit=10")!
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            artistAlbumsPageHandler: { _, _, _, offset, providedNext in
                if offset == 0 {
                    return MusicArtistAlbumsPage(
                        items: [MusicArtistAlbum(id: "alb-1", name: "First", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album, uri: "spotify:album:alb-1")],
                        next: nextURL
                    )
                }
                XCTAssertEqual(providedNext, nextURL)
                return MusicArtistAlbumsPage(
                    items: [MusicArtistAlbum(id: "alb-2", name: "Second", imageURL: nil, releaseYear: "2023", totalTracks: 1, group: .single, uri: "spotify:album:alb-2")],
                    next: nil
                )
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache(), initialArtistAlbumPageCount: 1)

        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")
        XCTAssertEqual(api.artistAlbumsPageCallCount, 1)
        await viewModel.loadMoreArtistAlbums()
        XCTAssertEqual(api.artistAlbumsPageCallCount, 2, "Load more should fetch exactly one additional albums page.")
    }

    /// A Load More that failed (#465) leaves the artist page open with what it has, and the
    /// next Load More asks for the same page again instead of ending the album list there.
    func testFailedLoadMoreArtistAlbumsIsAskedAgain() async {
        let nextURL = URL(string: "spotiglass-apple-music://artist-albums?offset=10")!
        var laterPageAttempts = 0
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            artistAlbumsPageHandler: { _, _, _, offset, _ in
                if offset == 0 {
                    return MusicArtistAlbumsPage(
                        items: [MusicArtistAlbum(id: "alb-1", name: "First", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album, uri: "apple-music:album:alb-1")],
                        next: nextURL
                    )
                }
                laterPageAttempts += 1
                if laterPageAttempts == 1 { throw URLError(.timedOut) }
                return MusicArtistAlbumsPage(
                    items: [MusicArtistAlbum(id: "alb-2", name: "Second", imageURL: nil, releaseYear: "2023", totalTracks: 1, group: .album, uri: "apple-music:album:alb-2")],
                    next: nil
                )
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache(), initialArtistAlbumPageCount: 1)
        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")

        await viewModel.loadMoreArtistAlbums()
        guard case let .staleCache(.artist(failed), error) = viewModel.detailState else {
            return XCTFail("A failed Load More must keep the artist page open, got \(viewModel.detailState)")
        }
        XCTAssertNotNil(error)
        XCTAssertEqual(failed.albums.map(\.id), ["alb-1"])
        XCTAssertTrue(failed.canLoadMoreAlbums)

        await viewModel.loadMoreArtistAlbums()
        XCTAssertEqual(laterPageAttempts, 2, "The failed page must be asked for again")
        guard case let .loaded(.artist(recovered)) = viewModel.detailState else {
            return XCTFail("Expected the artist page after the retried page, got \(viewModel.detailState)")
        }
        XCTAssertEqual(recovered.albums.map(\.id), ["alb-1", "alb-2"])
        XCTAssertFalse(recovered.canLoadMoreAlbums)
    }

    /// An artist page whose albums failed to load (#465) shows an error, and Retry (the same
    /// as Refresh) loads that artist again.
    func testFailedArtistPageRetriesTheSameArtist() async {
        var attempts = 0
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            artistAlbumsPageHandler: { _, _, _, _, _ in
                attempts += 1
                if attempts == 1 { throw URLError(.networkConnectionLost) }
                return MusicArtistAlbumsPage(
                    items: [MusicArtistAlbum(id: "alb-1", name: "First", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album, uri: "apple-music:album:alb-1")],
                    next: nil
                )
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache(), initialArtistAlbumPageCount: 1)
        await viewModel.load()
        await viewModel.selectArtist(id: "artist-xyz")
        guard case .error = viewModel.detailState else {
            return XCTFail("Expected an error state, got \(viewModel.detailState)")
        }

        await viewModel.unifiedRefreshMainSurface()

        XCTAssertEqual(attempts, 2)
        guard case let .loaded(.artist(detail)) = viewModel.detailState else {
            return XCTFail("Retry must load the artist again, got \(viewModel.detailState)")
        }
        XCTAssertEqual(detail.albums.map(\.id), ["alb-1"])
    }

    func testSignOutClearsBrowsingState() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        viewModel.clearForSignOut()

        XCTAssertNil(viewModel.selectedPlaylistID)
        guard case let .empty(playlistMessage) = viewModel.playlistState else {
            return XCTFail("Expected signed-out empty playlist state")
        }
        XCTAssertEqual(playlistMessage, "Connect Spotify to browse playlists.")
    }
}

private actor TestDeferred<Value> {
    private var value: Value?
    private var waiter: CheckedContinuation<Value, Never>?
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async -> Value {
        if let value {
            return value
        }
        return await withCheckedContinuation { continuation in
            waiter = continuation
            let waiters = blockedWaiters
            blockedWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilBlocked() async {
        if waiter != nil {
            return
        }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func resolve(_ value: Value) {
        self.value = value
        waiter?.resume(returning: value)
        waiter = nil
    }
}
