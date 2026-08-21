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
