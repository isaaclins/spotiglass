import XCTest
@testable import Spotiglass

@MainActor
final class PlaylistBrowserArtistSelectionCoverageTests: XCTestCase {
    func testSelectArtistUsesCachedSnapshotWithoutNetwork() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "t1")])]]
        )
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await vm.load()

        let artist = MusicArtistDetail(
            id: "artist-1",
            name: "Cached Artist",
            imageURL: nil,
            followersTotal: 10,
            genres: [],
            uri: "spotify:artist:artist-1"
        )
        let snapshot = PlaylistBrowserViewModel.ArtistDetailSnapshot(
            artistDetail: artist,
            albums: [],
            tracks: [],
            usedStaleCache: false,
            paging: nil
        )
        vm.cachedArtistSnapshots["artist-1"] = PlaylistBrowserViewModel.CachedArtistSnapshot(
            snapshot: snapshot,
            fetchedAt: Date()
        )

        await vm.selectArtist(id: "artist-1")
        guard case let .loaded(.artist(detail)) = vm.detailState else {
            return XCTFail("expected cached artist detail")
        }
        XCTAssertEqual(detail.artist.name, "Cached Artist")
    }

    func testCachedArtistNavigationClearsPreviousTrackSelection() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: [:]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        let artist = MusicArtistDetail(
            id: "artist-cached-selection",
            name: "Cached Selection",
            imageURL: nil,
            followersTotal: nil,
            genres: [],
            uri: "spotify:artist:artist-cached-selection"
        )
        let matchingTrack = PlaylistBrowsingTestFixtures.fallbackTrack(
            id: "same-id",
            name: "Matching Track",
            artistId: artist.id
        )
        viewModel.cachedArtistSnapshots[artist.id] = PlaylistBrowserViewModel.CachedArtistSnapshot(
            snapshot: PlaylistBrowserViewModel.ArtistDetailSnapshot(
                artistDetail: artist,
                albums: [],
                tracks: [matchingTrack],
                usedStaleCache: false,
                paging: nil
            ),
            fetchedAt: Date()
        )
        viewModel.selectedDetailTrackIDs = [matchingTrack.id]

        await viewModel.selectArtist(id: artist.id)

        XCTAssertTrue(viewModel.selectedDetailTrackIDs.isEmpty)
        XCTAssertTrue(viewModel.selectedTrackRows.isEmpty)
    }

    func testSelectArtistLoadsFromNetworkOnMiss() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "t1")])]],
            searchHandler: { _, _ in
                MusicSearchResults(
                    tracks: [PlaylistBrowsingTestFixtures.fallbackTrack(id: "search", name: "Search", artistId: "artist-net")],
                    artists: [],
                    albums: [],
                    playlists: []
                )
            },
            artistAlbumsHandler: { id, _, _ in
                XCTAssertEqual(id, "artist-net")
                return []
            }
        )
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await vm.load()

        await vm.selectArtist(id: "artist-net")
        guard case let .loaded(.artist(detail)) = vm.detailState else {
            return XCTFail("expected loaded artist")
        }
        XCTAssertEqual(detail.artist.id, "artist-net")
        XCTAssertFalse(detail.tracks.isEmpty)
    }

    func testSelectArtistCoalescesRapidRepeatRequests() async {
        let searchStarted = AsyncSignal()
        let releaseSearch = AsyncSignal()
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: [:],
            searchHandler: { _, _ in
                searchStarted.signal()
                await releaseSearch.wait()
                return MusicSearchResults(tracks: [], artists: [], albums: [], playlists: [])
            },
            artistAlbumsHandler: { _, _, _ in [] }
        )
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await vm.load()

        async let first: Void = vm.selectArtist(id: "coalesce")
        // the first artist request should be in flight before the duplicate
        await searchStarted.wait()
        await vm.selectArtist(id: "coalesce")
        releaseSearch.signal()
        await first
        XCTAssertGreaterThanOrEqual(vm.artistFetchMetrics.coalescedRequests, 1)
    }

    func testSelectArtistForceRefreshBypassesCache() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: [:],
            artistAlbumsHandler: { _, _, _ in [] }
        )
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await vm.load()

        let artist = MusicArtistDetail(
            id: "force-1",
            name: "Name From The Cache",
            imageURL: nil,
            followersTotal: 0,
            genres: [],
            uri: "spotify:artist:force-1"
        )
        let snapshot = PlaylistBrowserViewModel.ArtistDetailSnapshot(
            artistDetail: artist,
            albums: [],
            tracks: [],
            usedStaleCache: false,
            paging: nil
        )
        vm.cachedArtistSnapshots["force-1"] = PlaylistBrowserViewModel.CachedArtistSnapshot(
            snapshot: snapshot,
            fetchedAt: Date()
        )

        await vm.selectArtist(id: "force-1", forceRefresh: true)
        guard case let .loaded(.artist(detail)) = vm.detailState else {
            return XCTFail("expected loaded artist after force refresh")
        }
        XCTAssertEqual(detail.artist.id, "force-1")
        XCTAssertEqual(detail.artist.name, "Artist force-1", "a forced refresh showed the cached artist")
        XCTAssertEqual(api.artistAlbumsPageCallCount, 1, "a forced refresh must ask the network")
    }

    /// A snapshot older than the cache's lifetime isn't shown: opening the artist asks the
    /// network again and shows what it answers, then keeps that answer as the new snapshot.
    func testSelectArtistRefetchesOnceTheCachedSnapshotIsOlderThanItsLifetime() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: [:],
            artistAlbumsHandler: { _, _, _ in [] }
        )
        let opened = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let ttl: TimeInterval = 90
        let vm = PlaylistBrowserViewModel(
            api: api,
            cache: MockBrowsingCache(),
            now: { opened },
            artistDetailCacheTTL: ttl
        )
        await vm.load()

        let cachedArtist = MusicArtistDetail(
            id: "stale-art",
            name: "Name From The Old Snapshot",
            imageURL: nil,
            followersTotal: 0,
            genres: [],
            uri: "spotify:artist:stale-art"
        )
        vm.cachedArtistSnapshots["stale-art"] = PlaylistBrowserViewModel.CachedArtistSnapshot(
            snapshot: PlaylistBrowserViewModel.ArtistDetailSnapshot(
                artistDetail: cachedArtist,
                albums: [],
                tracks: [],
                usedStaleCache: false,
                paging: nil
            ),
            fetchedAt: opened.addingTimeInterval(-(ttl + 1))
        )

        await vm.selectArtist(id: "stale-art")

        guard case let .loaded(.artist(detail)) = vm.detailState else {
            return XCTFail("expected the refetched artist, got \(vm.detailState)")
        }
        XCTAssertEqual(detail.artist.name, "Artist stale-art", "the expired snapshot was shown instead of asking again")
        XCTAssertEqual(api.artistAlbumsPageCallCount, 1, "an expired snapshot must be fetched again")
        XCTAssertEqual(vm.cachedArtistSnapshots["stale-art"]?.fetchedAt, opened, "the new answer replaces the old snapshot")
        XCTAssertEqual(vm.cachedArtistSnapshots["stale-art"]?.snapshot.artistDetail.name, "Artist stale-art")
    }

    /// The same snapshot one second before it expires is still shown without asking.
    func testSelectArtistKeepsTheCachedSnapshotUntilItsLifetimeEnds() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: [:],
            artistAlbumsHandler: { _, _, _ in [] }
        )
        let opened = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let ttl: TimeInterval = 90
        let vm = PlaylistBrowserViewModel(
            api: api,
            cache: MockBrowsingCache(),
            now: { opened },
            artistDetailCacheTTL: ttl
        )
        await vm.load()
        vm.cachedArtistSnapshots["fresh-art"] = PlaylistBrowserViewModel.CachedArtistSnapshot(
            snapshot: PlaylistBrowserViewModel.ArtistDetailSnapshot(
                artistDetail: MusicArtistDetail(
                    id: "fresh-art", name: "Cached Name", imageURL: nil, followersTotal: 0, genres: [], uri: "spotify:artist:fresh-art"
                ),
                albums: [],
                tracks: [],
                usedStaleCache: false,
                paging: nil
            ),
            fetchedAt: opened.addingTimeInterval(-(ttl - 1))
        )

        await vm.selectArtist(id: "fresh-art")

        guard case let .loaded(.artist(detail)) = vm.detailState else {
            return XCTFail("expected the cached artist, got \(vm.detailState)")
        }
        XCTAssertEqual(detail.artist.name, "Cached Name")
        XCTAssertEqual(api.artistAlbumsPageCallCount, 0, "a snapshot inside its lifetime needs no network")
    }

    func testSelectArtistWithDisplayNameUsesBreadcrumbLabel() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: [:],
            artistAlbumsHandler: { _, _, _ in [] }
        )
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await vm.load()
        await vm.selectArtist(id: "named", displayName: "Display")
        guard case let .loaded(.artist(detail)) = vm.detailState else {
            return XCTFail("expected artist detail")
        }
        XCTAssertEqual(detail.artist.id, "named")
    }
}
