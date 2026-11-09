import XCTest
@testable import Spotiglass

@MainActor
final class PlaylistBrowserMainSurfaceRefreshTests: XCTestCase {
    func testUnifiedRefreshMainSurfaceFromHomeRefreshesLibrary() async {
        let api = MockBrowsingAPI(
            playlistResults: [
                .success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")]),
                .success([PlaylistBrowsingTestFixtures.playlist(id: "two", name: "Two")]),
            ],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "t1")])]]
        )
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await vm.load()
        await vm.selectSidebar(.home)
        await vm.unifiedRefreshMainSurface()
        XCTAssertEqual(vm.playlistState.currentValue?.map(\.title), ["Two"])
    }

    func testUnifiedRefreshMainSurfaceFromSearchRerunsActiveQuery() async {
        let vm = PlaylistBrowserViewModel(
            api: MockBrowsingAPI(playlistResults: [], trackResults: [:]),
            cache: MockBrowsingCache()
        )
        await vm.selectSidebar(.search)
        vm.catalogSearch.query = "found"
        defer {
            vm.catalogSearch.query = ""
            vm.catalogSearch.scheduleSearch()
        }

        await vm.unifiedRefreshMainSurface()

        guard case .loading = vm.catalogSearch.state else {
            return XCTFail("Refreshing the search surface must schedule a fresh search")
        }
    }

    func testPerformUnifiedRefreshRoutesToQueueWhenFocused() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "t1")])]]
        )
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await vm.load()
        vm.refreshRoutingQueuePanelVisible = true
        vm.refreshRoutingQueuePanelFocused = true
        var queueRefreshed = false
        await vm.performUnifiedRefresh(queueRefresh: { queueRefreshed = true })
        XCTAssertTrue(queueRefreshed)
    }

    func testUnifiedRefreshFromLikedSongsInvalidatesItsTrackCache() async {
        let playlist = PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")
        let cache = MockBrowsingCache(
            cachedPlaylists: [playlist],
            cachedTracks: [SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID: [
                PlaylistBrowsingTestFixtures.track(id: "stale-liked")
            ]],
            playlistListCacheAge: 5
        )
        let api = MockBrowsingAPI(
            playlistResults: [.success([playlist])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "t1")])]],
            savedTracksResult: .success(MusicSavedTracksResult(
                tracks: [PlaylistBrowsingTestFixtures.track(id: "fresh-liked")],
                totalAvailable: 1
            ))
        )
        let vm = PlaylistBrowserViewModel(api: api, cache: cache)
        await vm.load()
        await vm.selectSidebar(.likedSongs)

        await vm.unifiedRefreshMainSurface()

        XCTAssertTrue(
            cache.invalidatedTrackPlaylistIDs.contains(SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID),
            "Refreshing Liked Songs must drop its cached tracks so the reload hits Spotify."
        )
    }

    func testUnifiedRefreshFromPinnedItemLeavesDetailAlone() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "t1")])]]
        )
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await vm.load()
        vm.sidebarSelection = .pinnedItem("pin-1")
        let sessionBefore = vm.detailSession

        await vm.unifiedRefreshMainSurface()

        XCTAssertEqual(vm.detailSession, sessionBefore, "A pinned row owns no reloadable detail.")
    }

    /// #438: with the lyrics open, Refresh (toolbar, ⌘R, View menu, palette: all end here)
    /// reloaded the playlist hidden under them. It does nothing now, for the page and the queue.
    func testPerformUnifiedRefreshWithLyricsPresentedDoesNothing() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "t1")])]]
        )
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await vm.load()
        vm.sidebarSelection = .playlist("one")
        await vm.unifiedRefreshMainSurface()
        let sessionBefore = vm.detailSession
        vm.refreshRoutingLyricsPresented = true
        vm.refreshRoutingQueuePanelVisible = true
        vm.refreshRoutingQueuePanelFocused = true
        var queueRefreshed = false

        await vm.performUnifiedRefresh(queueRefresh: { queueRefreshed = true })

        XCTAssertFalse(queueRefreshed, "Refresh reloaded the queue while the lyrics were open.")
        XCTAssertEqual(vm.detailSession, sessionBefore, "Refresh reloaded the page under the lyrics.")

        // Closing the lyrics brings Refresh back.
        vm.refreshRoutingLyricsPresented = false
        vm.refreshRoutingQueuePanelFocused = false
        await vm.performUnifiedRefresh(queueRefresh: { queueRefreshed = true })
        XCTAssertGreaterThan(vm.detailSession, sessionBefore, "Refresh stayed off after the lyrics closed.")
    }

    func testPerformUnifiedRefreshWithoutQueueFocusRefreshesTheMainSurface() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "t1")])]]
        )
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await vm.load()
        vm.refreshRoutingQueuePanelVisible = true
        vm.refreshRoutingQueuePanelFocused = false
        var queueRefreshed = false

        await vm.performUnifiedRefresh(queueRefresh: { queueRefreshed = true })

        XCTAssertFalse(queueRefreshed, "A visible but unfocused queue panel does not own the refresh.")
    }

    func testRefreshSelectedPlaylistReloadsArtistDetail() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "t1")])]],
            artistAlbumsHandler: { _, _, _ in [] }
        )
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await vm.load()
        await vm.selectArtist(id: "artist-1")
        await vm.refreshSelectedPlaylist()
        guard case let .loaded(.artist(detail)) = vm.detailState else {
            return XCTFail("expected artist detail")
        }
        XCTAssertEqual(detail.artist.name, "Artist artist-1")
    }
}
