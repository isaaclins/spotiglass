import XCTest

@testable import Spotiglass

@MainActor
final class PlaylistBrowserSidebarSelectionHandlingTests: XCTestCase {
    func testSelectionChangeActionRoutesPinnedItem() {
        let item = PinnedItem.playlist(PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "One"))
        let action = PlaylistBrowserSidebarSelectionHandling.selectionChangeAction(
            oldValue: .home,
            newValue: .pinnedItem(item.id),
            pinnedItems: [item]
        )
        guard case .activatePinned(let activated) = action else {
            return XCTFail("expected activatePinned, got \(action)")
        }
        XCTAssertEqual(activated.id, item.id)
    }

    func testSelectionChangeActionSelectsSidebarForPlaylist() {
        let action = PlaylistBrowserSidebarSelectionHandling.selectionChangeAction(
            oldValue: .home,
            newValue: .playlist("p1"),
            pinnedItems: []
        )
        XCTAssertEqual(action, .selectSidebar(.playlist("p1")))
    }

    func testSelectionChangeActionNoOpWhenUnchanged() {
        XCTAssertEqual(
            PlaylistBrowserSidebarSelectionHandling.selectionChangeAction(
                oldValue: .home,
                newValue: .home,
                pinnedItems: []
            ),
            .none
        )
    }

    func testActivatePinnedPlaylistSelectsSidebar() async {
        var selectedPlaylist: String?
        var markedStale: (String, Bool)?
        await PlaylistBrowserSidebarSelectionHandling.activatePinnedItem(
            PinnedItem.playlist(PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "One")),
            previousSelection: .home,
            lastNonPinnedSelection: .home,
            callbacks: makeCallbacks(
                selectSidebarPlaylist: { selectedPlaylist = $0 },
                markStale: { id, stale in markedStale = (id, stale) },
                detailState: .loaded(
                    .playlist(
                        PlaylistDetailViewModel(
                            playlist: PlaylistRowViewModel(
                                PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "One")),
                            tracks: []
                        )))
            )
        )
        XCTAssertEqual(selectedPlaylist, "p1")
        XCTAssertEqual(markedStale?.1, false)
    }

    func testActivatePinnedTrackPlaysAndRevertsSelection() async {
        var playedURI: String?
        var sidebar: SidebarSelection?
        let track = PlaylistBrowsingTestFixtures.fallbackTrack(id: "t1", name: "Track", artistId: "a1")
        await PlaylistBrowserSidebarSelectionHandling.activatePinnedItem(
            PinnedItem.track(track),
            previousSelection: .playlist("prev"),
            lastNonPinnedSelection: .home,
            callbacks: makeCallbacks(
                setSidebarSelection: { sidebar = $0 },
                playURI: { playedURI = $0 }
            )
        )
        XCTAssertEqual(playedURI, track.uri)
        XCTAssertEqual(sidebar, .playlist("prev"))
    }

    func testActivateStalePinnedRevertsSelection() async {
        var item = PinnedItem.playlist(PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "One"))
        item.isStale = true
        var sidebar: SidebarSelection?
        await PlaylistBrowserSidebarSelectionHandling.activatePinnedItem(
            item,
            previousSelection: .pinnedItem(item.id),
            lastNonPinnedSelection: .home,
            callbacks: makeCallbacks(setSidebarSelection: { sidebar = $0 })
        )
        XCTAssertEqual(sidebar, .home)
    }

    private func makeCallbacks(
        setSidebarSelection: @escaping (SidebarSelection?) -> Void = { _ in },
        selectSidebarPlaylist: @escaping (String) async -> Void = { _ in },
        selectArtist: @escaping (String, BrowserNavigationOrigin, String?) async -> Void = { _, _, _ in },
        selectAlbum: @escaping (String, String, String, URL?, BrowserNavigationOrigin) async -> Void = {
            _, _, _, _, _ in
        },
        playURI: @escaping (String) async -> Void = { _ in },
        markStale: @escaping (String, Bool) -> Void = { _, _ in },
        detailState: BrowsingLoadState<BrowsingDetailContent> = .loading
    ) -> PlaylistBrowserSidebarSelectionHandling.ActivationCallbacks {
        .init(
            setSidebarSelection: setSidebarSelection,
            selectSidebarPlaylist: selectSidebarPlaylist,
            selectArtist: selectArtist,
            selectAlbum: selectAlbum,
            playURI: playURI,
            markStale: markStale,
            detailState: { detailState }
        )
    }
}
