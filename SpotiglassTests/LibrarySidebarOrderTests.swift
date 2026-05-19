import SwiftUI
import ViewInspector
import XCTest
@testable import Spotiglass

@MainActor
final class LibrarySidebarOrderTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    func testNormalizedOrderMigratesPinnedFirstWhenMissing() {
        let order = LibrarySidebarOrder.normalizedOrder(
            existing: [LibrarySidebarOrder.homeToken],
            pinnedItemIDs: ["a", "b"]
        )
        XCTAssertEqual(order, ["pinned:a", "pinned:b", LibrarySidebarOrder.homeToken])
    }

    func testNormalizedOrderPreservesExistingPinnedAndAppendsHome() {
        let existing = ["pinned:b", LibrarySidebarOrder.homeToken]
        let order = LibrarySidebarOrder.normalizedOrder(existing: existing, pinnedItemIDs: ["a", "b"])
        XCTAssertEqual(order.first, "pinned:b")
        XCTAssertTrue(order.contains(LibrarySidebarOrder.homeToken))
        XCTAssertTrue(order.contains("pinned:a"))
    }

    func testMovedReordersToken() {
        let order = ["pinned:a", LibrarySidebarOrder.homeToken, "pinned:b"]
        let moved = LibrarySidebarOrder.moved(order: order, movingToken: "pinned:b", toInsertionIndex: 0)
        XCTAssertEqual(moved.first, "pinned:b")
    }

    func testPinnedInsertionIndexCountsPinnedPrefix() {
        let order = ["pinned:a", LibrarySidebarOrder.homeToken, "pinned:b"]
        let idx = LibrarySidebarOrder.pinnedInsertionIndex(
            order: order,
            movingPinnedToken: "pinned:b",
            toInsertionIndex: 1
        )
        XCTAssertEqual(idx, 1)
    }

    func testPinnedTokenRoundTrip() {
        XCTAssertEqual(LibrarySidebarOrder.pinnedItemID(from: "pinned:xyz"), "xyz")
        XCTAssertNil(LibrarySidebarOrder.pinnedItemID(from: LibrarySidebarOrder.homeToken))
        XCTAssertEqual(LibrarySidebarOrder.pinnedToken(for: "id"), "pinned:id")
    }

    func testPinnedDropSkeletonRowInspectable() throws {
        let item = PinnedItem.playlist(PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "Playlist"))
        let withItem = PinnedDropSkeletonRow(item: item)
        ViewTestHost.host(withItem, size: CGSize(width: 280, height: 64))
        XCTAssertNoThrow(try withItem.inspect())

        let empty = PinnedDropSkeletonRow(item: nil)
        ViewTestHost.host(empty, size: CGSize(width: 280, height: 64))
        XCTAssertNoThrow(try empty.inspect())
    }
}
