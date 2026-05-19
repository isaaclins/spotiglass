import SwiftUI
import ViewInspector
import XCTest
@testable import Spotiglass

@MainActor
final class PlaylistBrowserChromeViewsTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    func testPlaylistsSidebarSectionHeaderStates() throws {
        let refreshing = PlaylistsSidebarSectionHeader(
            playlistState: .refreshing([PlaylistRowViewModel(
                PlaylistBrowsingTestFixtures.playlist(id: "p", name: "Mix")
            )])
        )
        ViewTestHost.host(refreshing)
        XCTAssertNoThrow(try refreshing.inspect().find(text: "Refreshing"))

        let stale = PlaylistsSidebarSectionHeader(
            playlistState: .staleCache(
                [],
                BrowsingDisplayError(title: "Stale", message: "Cached", canRetry: true)
            )
        )
        ViewTestHost.host(stale)
        XCTAssertNoThrow(try stale.inspect().find(text: "Showing cached data"))
    }

    func testLibraryHomeSidebarRow() throws {
        let row = LibraryHomeSidebarRow()
        ViewTestHost.host(row)
        XCTAssertNoThrow(try row.inspect().find(text: "Home"))
    }

    func testPinnedSidebarLibraryRow() throws {
        let pin = PinnedItem.playlist(
            PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "Pinned Mix")
        )
        let store = PinnedItemsStore(cache: InMemoryPinnedItemsCache())
        store.bind(userID: "test-user")
        store.pin(pin)
        let row = PinnedSidebarLibraryRow(item: pin, isSelected: true)
            .environmentObject(store)
        ViewTestHost.host(row)
        XCTAssertNoThrow(try row.inspect().find(text: "Pinned Mix"))
    }
}
