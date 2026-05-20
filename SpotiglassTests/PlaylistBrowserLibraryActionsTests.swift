import XCTest
@testable import Spotiglass

final class PlaylistBrowserLibraryActionsTests: XCTestCase {
    func testLibraryRowsAndPinnedDropPlans() {
        let playlist = PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "One")
        let pinned = PinnedItem.playlist(playlist)
        let order = [
            LibrarySidebarOrder.homeToken,
            LibrarySidebarOrder.pinnedToken(for: pinned.id),
        ]
        let rows = PlaylistBrowserLibraryActions.libraryRows(
            order: order,
            pinnedItems: [pinned, PinnedItem.likedSongs(ownerDisplay: "You", artworkURL: nil)]
        )
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], .home)
        if case let .pinned(item) = rows[1] {
            XCTAssertEqual(item.id, pinned.id)
        } else {
            XCTFail("expected pinned row")
        }

        let transfer = LibrarySidebarRowTransfer(rowToken: LibrarySidebarOrder.homeToken)
        let moved = PlaylistBrowserLibraryActions.movedLibraryRowOrder(
            order: order,
            transfer: transfer,
            insertionIndex: 1
        )
        XCTAssertNotNil(moved)

        let pinTransfer = PinnedItemTransfer(item: pinned, originScopeID: PinnedItemTransfer.pinnedSidebarScopeID)
        let reorderPlan = PlaylistBrowserLibraryActions.planPinnedTransferDrop(
            order: order,
            transfer: pinTransfer,
            insertionIndex: 0
        )
        XCTAssertNotNil(reorderPlan?.pinnedReorderItemID)

        let externalTransfer = PinnedItemTransfer(item: pinned, originScopeID: "other")
        let pinPlan = PlaylistBrowserLibraryActions.planPinnedTransferDrop(
            order: order,
            transfer: externalTransfer,
            insertionIndex: 1
        )
        XCTAssertEqual(pinPlan?.pinItem?.id, pinned.id)
    }

    func testLibraryAndPinnedTransferDropApplications() {
        let playlist = PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "One")
        let pinned = PinnedItem.playlist(playlist)
        let order = [LibrarySidebarOrder.homeToken, LibrarySidebarOrder.pinnedToken(for: pinned.id)]

        let moved = PlaylistBrowserLibraryActions.updatedOrderForLibraryTransferDrop(
            order: order,
            transfers: [LibrarySidebarRowTransfer(rowToken: LibrarySidebarOrder.homeToken)],
            insertionIndex: 1
        )
        XCTAssertNotNil(moved)

        let application = PlaylistBrowserLibraryActions.pinnedTransferDropApplication(
            order: order,
            transfers: [PinnedItemTransfer(item: pinned, originScopeID: PinnedItemTransfer.pinnedSidebarScopeID)],
            insertionIndex: 0
        )
        XCTAssertEqual(application?.reorderItemID, pinned.id)

        let synced = PlaylistBrowserLibraryActions.libraryRowOrderAfterSync(
            existing: [LibrarySidebarOrder.homeToken],
            visiblePinnedItemIDs: [pinned.id]
        )
        XCTAssertTrue(synced.contains(LibrarySidebarOrder.pinnedToken(for: pinned.id)))
    }

    func testPlaylistSummaryFromRow() {
        let row = PlaylistRowViewModel(PlaylistBrowsingTestFixtures.playlist(id: "x", name: "Title"))
        let summary = PlaylistBrowserLibraryActions.playlistSummaryFromRow(row)
        XCTAssertEqual(summary.id, "x")
        XCTAssertEqual(summary.name, "Title")
    }
}
