import XCTest
@testable import Spotiglass

final class PlaylistBrowserTypesTests: XCTestCase {
    func testLibrarySidebarRowHomeIdentity() {
        let row = LibrarySidebarRow.home
        XCTAssertEqual(row.id, LibrarySidebarOrder.homeToken)
        XCTAssertEqual(row.sidebarSelectionTag, .home)
    }

    func testLibrarySidebarRowPinnedIdentity() {
        let playlist = PlaylistBrowsingTestFixtures.playlist(id: "pl1", name: "Mix")
        let item = PinnedItem.playlist(playlist)
        let row = LibrarySidebarRow.pinned(item)
        XCTAssertEqual(row.id, LibrarySidebarOrder.pinnedToken(for: item.id))
        XCTAssertEqual(row.sidebarSelectionTag, .pinnedItem(item.id))
    }

    func testBrowserWidthSamplerDefaults() {
        let sampler = BrowserWidthSampler()
        XCTAssertEqual(sampler.latestWidth, 2000, accuracy: 0.01)
    }

    func testUnifiedRefreshFocusHashable() {
        XCTAssertEqual(UnifiedRefreshFocus.mainContent, UnifiedRefreshFocus.mainContent)
        XCTAssertNotEqual(UnifiedRefreshFocus.mainContent, UnifiedRefreshFocus.queuePanel)
    }
}
