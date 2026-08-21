import XCTest
@testable import Spotiglass

@MainActor
final class PlaylistBrowserConcurrencyTests: XCTestCase {

    func testConcurrentSelectArtistCoalescesSingleNetworkChain() async {
        let page1 = SpotifyArtistAlbum(
            id: "alb-1", name: "First", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album, uri: "spotify:album:alb-1"
        )
        let page2 = SpotifyArtistAlbum(
            id: "alb-2", name: "Second", imageURL: nil, releaseYear: "2023", totalTracks: 1, group: .album, uri: "spotify:album:alb-2"
        )
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "track-one")])]],
            artistAlbumsPageHandler: { _, _, _, offset, _ in
                try await Task.sleep(nanoseconds: 50_000_000)
                if offset == 0 {
                    return SpotifyAPIClient.SpotifyArtistAlbumsPage(
                        items: [page1],
                        next: URL(string: "https://api.spotify.com/v1/artists/artist-xyz/albums?offset=10&limit=10")
                    )
                }
                return SpotifyAPIClient.SpotifyArtistAlbumsPage(items: [page2], next: nil)
            }
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        async let first: Void = viewModel.selectArtist(id: "artist-xyz")
        async let second: Void = viewModel.selectArtist(id: "artist-xyz")
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
                    return SpotifyAPIClient.SpotifyArtistAlbumsPage(
                        items: [SpotifyArtistAlbum(id: "alb-1", name: "First", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album, uri: "spotify:album:alb-1")],
                        next: nil
                    )
                }
                return SpotifyAPIClient.SpotifyArtistAlbumsPage(items: [], next: nil)
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
        let pageA1 = SpotifyArtistAlbum(
            id: "a-alb-1", name: "A First", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album, uri: "spotify:album:a-alb-1"
        )
        let pageA2 = SpotifyArtistAlbum(
            id: "a-alb-2", name: "A Second", imageURL: nil, releaseYear: "2023", totalTracks: 1, group: .album, uri: "spotify:album:a-alb-2"
        )
        let pageB1 = SpotifyArtistAlbum(
            id: "b-alb-1", name: "B First", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album, uri: "spotify:album:b-alb-1"
        )
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: [:],
            artistAlbumsPageHandler: { id, _, _, offset, _ in
                if id == "artist-a" {
                    if offset == 0 {
                        return SpotifyAPIClient.SpotifyArtistAlbumsPage(items: [pageA1], next: firstPageURL)
                    }
                    await aLoadMoreGate.wait()
                    return SpotifyAPIClient.SpotifyArtistAlbumsPage(items: [pageA2], next: nil)
                }
                return SpotifyAPIClient.SpotifyArtistAlbumsPage(items: [pageB1], next: nil)
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
        let pageA1 = SpotifyArtistAlbum(
            id: "a-alb-1", name: "A First", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album, uri: "spotify:album:a-alb-1"
        )
        let pageB1 = SpotifyArtistAlbum(
            id: "b-alb-1", name: "B First", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album, uri: "spotify:album:b-alb-1"
        )
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: [:],
            artistAlbumsPageHandler: { id, _, _, offset, _ in
                if id == "artist-a" {
                    if offset == 0 {
                        return SpotifyAPIClient.SpotifyArtistAlbumsPage(items: [pageA1], next: firstPageURL)
                    }
                    await aLoadMoreGate.wait()
                    throw LoadMoreFailure()
                }
                return SpotifyAPIClient.SpotifyArtistAlbumsPage(items: [pageB1], next: nil)
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
                    return SpotifyAPIClient.SpotifyArtistAlbumsPage(
                        items: [SpotifyArtistAlbum(id: "alb-1", name: "First", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album, uri: "spotify:album:alb-1")],
                        next: nextURL
                    )
                }
                await loadMoreGate.wait()
                return SpotifyAPIClient.SpotifyArtistAlbumsPage(items: [], next: nil)
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
                    return SpotifyAPIClient.SpotifyArtistAlbumsPage(
                        items: [SpotifyArtistAlbum(id: "alb-1", name: "First", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album, uri: "spotify:album:alb-1")],
                        next: nextURL
                    )
                }
                XCTAssertEqual(providedNext, nextURL)
                return SpotifyAPIClient.SpotifyArtistAlbumsPage(
                    items: [SpotifyArtistAlbum(id: "alb-2", name: "Second", imageURL: nil, releaseYear: "2023", totalTracks: 1, group: .single, uri: "spotify:album:alb-2")],
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
