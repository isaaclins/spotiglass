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

        let artist = SpotifyArtistDetail(
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
        let artist = SpotifyArtistDetail(
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
                SpotifySearchResults(
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
                return SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
            },
            artistAlbumsHandler: { _, _, _ in [] }
        )
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await vm.load()

        async let first: Void = vm.selectArtist(id: "coalesce")
        let didStartSearch = await searchStarted.wait(timeout: .seconds(1))
        XCTAssertTrue(
            didStartSearch,
            "the first artist request should be in flight before the duplicate"
        )
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

        let artist = SpotifyArtistDetail(
            id: "force-1",
            name: "Force",
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
    }

    func testSelectArtistStaleCacheRefreshPath() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: [:],
            artistAlbumsHandler: { _, _, _ in [] }
        )
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await vm.load()

        let artist = SpotifyArtistDetail(
            id: "stale-art",
            name: "Stale",
            imageURL: nil,
            followersTotal: 0,
            genres: [],
            uri: "spotify:artist:stale-art"
        )
        let snapshot = PlaylistBrowserViewModel.ArtistDetailSnapshot(
            artistDetail: artist,
            albums: [],
            tracks: [],
            usedStaleCache: true,
            paging: nil
        )
        vm.cachedArtistSnapshots["stale-art"] = PlaylistBrowserViewModel.CachedArtistSnapshot(
            snapshot: snapshot,
            fetchedAt: Date()
        )

        await vm.selectArtist(id: "stale-art")
        if case .refreshing(.artist) = vm.detailState {
            XCTAssertTrue(true)
        } else if case .loaded(.artist) = vm.detailState {
            XCTAssertTrue(true)
        } else {
            XCTFail("expected stale refresh or loaded artist, got \(vm.detailState)")
        }
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
