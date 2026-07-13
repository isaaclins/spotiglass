import XCTest
@testable import Spotiglass

final class PlaylistBrowserLibraryActionsTests: XCTestCase {
    func testLibraryRowsMapTokensAndHideLikedSongs() {
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
    }

    func testLibraryRowsDropStaleTokens() {
        let playlist = PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "One")
        let pinned = PinnedItem.playlist(playlist)
        let order = [
            "pinned:removed",
            LibrarySidebarOrder.pinnedToken(for: pinned.id),
            LibrarySidebarOrder.homeToken,
        ]
        let rows = PlaylistBrowserLibraryActions.libraryRows(order: order, pinnedItems: [pinned])
        XCTAssertEqual(rows.count, 2)
    }

    func testMovedLibraryRowOrderMovesRowDown() {
        let pinA = PinnedItem.playlist(PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "One"))
        let pinB = PinnedItem.playlist(PlaylistBrowsingTestFixtures.playlist(id: "p2", name: "Two"))
        let rows: [LibrarySidebarRow] = [.pinned(pinA), .pinned(pinB), .home]

        // List.onMove semantics: moving index 0 to offset 2 places A between B and Home.
        let moved = PlaylistBrowserLibraryActions.movedLibraryRowOrder(
            rows: rows,
            fromOffsets: IndexSet(integer: 0),
            toOffset: 2
        )
        XCTAssertEqual(
            moved,
            [
                LibrarySidebarOrder.pinnedToken(for: pinB.id),
                LibrarySidebarOrder.pinnedToken(for: pinA.id),
                LibrarySidebarOrder.homeToken,
            ]
        )
    }

    func testMovedLibraryRowOrderMovesRowUp() {
        let pinA = PinnedItem.playlist(PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "One"))
        let pinB = PinnedItem.playlist(PlaylistBrowsingTestFixtures.playlist(id: "p2", name: "Two"))
        let rows: [LibrarySidebarRow] = [.home, .pinned(pinA), .pinned(pinB)]

        let moved = PlaylistBrowserLibraryActions.movedLibraryRowOrder(
            rows: rows,
            fromOffsets: IndexSet(integer: 2),
            toOffset: 0
        )
        XCTAssertEqual(
            moved,
            [
                LibrarySidebarOrder.pinnedToken(for: pinB.id),
                LibrarySidebarOrder.homeToken,
                LibrarySidebarOrder.pinnedToken(for: pinA.id),
            ]
        )
    }

    func testLibraryRowOrderAfterSyncKeepsNewPinsAboveTrailingHome() {
        let synced = PlaylistBrowserLibraryActions.libraryRowOrderAfterSync(
            existing: ["pinned:a", LibrarySidebarOrder.homeToken],
            visiblePinnedItemIDs: ["a", "b"]
        )
        XCTAssertEqual(synced, ["pinned:a", "pinned:b", LibrarySidebarOrder.homeToken])
    }

    func testLibraryRowOrderStoreRoundTrip() throws {
        let suiteName = "LibraryRowOrderStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(LibraryRowOrderStore.load(userID: "user-a", defaults: defaults))

        let order = ["pinned:a", LibrarySidebarOrder.homeToken, "pinned:b"]
        LibraryRowOrderStore.save(order, userID: "user-a", defaults: defaults)
        XCTAssertEqual(LibraryRowOrderStore.load(userID: "user-a", defaults: defaults), order)
        XCTAssertNil(LibraryRowOrderStore.load(userID: "user-b", defaults: defaults))
    }

    func testLibraryRowOrderStoreOverwritesPreviousOrder() throws {
        let suiteName = "LibraryRowOrderStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        LibraryRowOrderStore.save(["pinned:a", LibrarySidebarOrder.homeToken], userID: "user-a", defaults: defaults)
        LibraryRowOrderStore.save([LibrarySidebarOrder.homeToken, "pinned:a"], userID: "user-a", defaults: defaults)
        XCTAssertEqual(
            LibraryRowOrderStore.load(userID: "user-a", defaults: defaults),
            [LibrarySidebarOrder.homeToken, "pinned:a"]
        )
    }

    func testPlaylistSummaryFromRow() {
        let row = PlaylistRowViewModel(PlaylistBrowsingTestFixtures.playlist(id: "x", name: "Title"))
        let summary = PlaylistBrowserLibraryActions.playlistSummaryFromRow(row)
        XCTAssertEqual(summary.id, "x")
        XCTAssertEqual(summary.name, "Title")
    }
}
