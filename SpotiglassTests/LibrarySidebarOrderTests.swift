import XCTest
@testable import Spotiglass

final class LibrarySidebarOrderTests: XCTestCase {
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

    func testNormalizedOrderInsertsNewPinsBeforeTrailingHome() {
        let existing = ["pinned:a", LibrarySidebarOrder.homeToken]
        let order = LibrarySidebarOrder.normalizedOrder(existing: existing, pinnedItemIDs: ["a", "b", "c"])
        XCTAssertEqual(order, ["pinned:a", "pinned:b", "pinned:c", LibrarySidebarOrder.homeToken])
    }

    func testNormalizedOrderInsertsNewPinsAfterLastPinWhenHomeIsFirst() {
        let existing = [LibrarySidebarOrder.homeToken, "pinned:a"]
        let order = LibrarySidebarOrder.normalizedOrder(existing: existing, pinnedItemIDs: ["a", "b"])
        XCTAssertEqual(order, [LibrarySidebarOrder.homeToken, "pinned:a", "pinned:b"])
    }

    func testNormalizedOrderDropsStalePinnedTokens() {
        let existing = ["pinned:a", "pinned:removed", LibrarySidebarOrder.homeToken]
        let order = LibrarySidebarOrder.normalizedOrder(existing: existing, pinnedItemIDs: ["a"])
        XCTAssertEqual(order, ["pinned:a", LibrarySidebarOrder.homeToken])
    }

    func testPinnedTokenRoundTrip() {
        XCTAssertEqual(LibrarySidebarOrder.pinnedItemID(from: "pinned:xyz"), "xyz")
        XCTAssertNil(LibrarySidebarOrder.pinnedItemID(from: LibrarySidebarOrder.homeToken))
        XCTAssertEqual(LibrarySidebarOrder.pinnedToken(for: "id"), "pinned:id")
    }
}
