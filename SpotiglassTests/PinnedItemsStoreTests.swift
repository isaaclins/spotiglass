import XCTest
@testable import Spotiglass

private final class RecordingPinnedCache: PinnedItemsCache {
    var saved: [String: [PinnedItem]] = [:]

    func loadPinnedItems(userID: String) throws -> [PinnedItem] {
        saved[userID] ?? []
    }

    func savePinnedItems(_ items: [PinnedItem], userID: String) throws {
        saved[userID] = items
    }
}

@MainActor
final class PinnedItemsStoreTests: XCTestCase {
    func testPinDedupesSameId() {
        let cache = RecordingPinnedCache()
        let store = PinnedItemsStore(cache: cache)
        store.bind(userID: "u1")
        let playlist = PinnedItem.playlist(
            SpotifyPlaylistSummary(
                id: "p1",
                name: "A",
                description: nil,
                ownerName: "o",
                imageURL: nil,
                trackCount: 0,
                isPublic: nil,
                isCollaborative: false,
                snapshotID: "s"
            )
        )
        XCTAssertTrue(store.pin(playlist))
        XCTAssertFalse(store.pin(playlist))
        XCTAssertEqual(store.items.count, 1)
    }

    func testReorderMovesItem() {
        let cache = RecordingPinnedCache()
        let store = PinnedItemsStore(cache: cache)
        store.bind(userID: "u1")
        let a = PinnedItem.playlist(
            SpotifyPlaylistSummary(id: "a", name: "A", description: nil, ownerName: "o", imageURL: nil, trackCount: 0, isPublic: nil, isCollaborative: false, snapshotID: "1")
        )
        let b = PinnedItem.playlist(
            SpotifyPlaylistSummary(id: "b", name: "B", description: nil, ownerName: "o", imageURL: nil, trackCount: 0, isPublic: nil, isCollaborative: false, snapshotID: "2")
        )
        store.pin(a)
        store.pin(b)
        store.reorder(itemID: a.id, toInsertionIndex: 2)
        XCTAssertEqual(store.items.map(\.spotifyID), ["b", "a"])
    }

    func testPinAtIndexInsertsMultipleDistinctItems() {
        let cache = RecordingPinnedCache()
        let store = PinnedItemsStore(cache: cache)
        store.bind(userID: "u1")
        let a = PinnedItem.playlist(
            SpotifyPlaylistSummary(id: "a", name: "A", description: nil, ownerName: "o", imageURL: nil, trackCount: 0, isPublic: nil, isCollaborative: false, snapshotID: "1")
        )
        let b = PinnedItem.playlist(
            SpotifyPlaylistSummary(id: "b", name: "B", description: nil, ownerName: "o", imageURL: nil, trackCount: 0, isPublic: nil, isCollaborative: false, snapshotID: "2")
        )
        let c = PinnedItem.playlist(
            SpotifyPlaylistSummary(id: "c", name: "C", description: nil, ownerName: "o", imageURL: nil, trackCount: 0, isPublic: nil, isCollaborative: false, snapshotID: "3")
        )

        XCTAssertTrue(store.pin(a, at: 0))
        XCTAssertTrue(store.pin(b, at: 0))
        XCTAssertTrue(store.pin(c, at: 1))
        XCTAssertEqual(store.items.map(\.spotifyID), ["b", "c", "a"])
    }

    func testReorderNoopWhenInsertionIndexKeepsSameOrder() {
        let cache = RecordingPinnedCache()
        let store = PinnedItemsStore(cache: cache)
        store.bind(userID: "u1")
        let a = PinnedItem.playlist(
            SpotifyPlaylistSummary(id: "a", name: "A", description: nil, ownerName: "o", imageURL: nil, trackCount: 0, isPublic: nil, isCollaborative: false, snapshotID: "1")
        )
        let b = PinnedItem.playlist(
            SpotifyPlaylistSummary(id: "b", name: "B", description: nil, ownerName: "o", imageURL: nil, trackCount: 0, isPublic: nil, isCollaborative: false, snapshotID: "2")
        )
        store.pin(a)
        store.pin(b)

        store.reorder(itemID: b.id, toInsertionIndex: 1)
        XCTAssertEqual(store.items.map(\.spotifyID), ["a", "b"])
    }

    func testPersistenceRoundTripPerUser() throws {
        let cache = RecordingPinnedCache()
        let store = PinnedItemsStore(cache: cache)
        store.bind(userID: "alice")
        let item = PinnedItem.artist(
            SpotifyArtist(id: "ar1", name: "Artist", imageURL: nil, uri: "spotify:artist:ar1")
        )
        store.pin(item)
        XCTAssertEqual(try cache.loadPinnedItems(userID: "alice").count, 1)

        let store2 = PinnedItemsStore(cache: cache)
        store2.bind(userID: "alice")
        XCTAssertEqual(store2.items.count, 1)
        XCTAssertEqual(store2.items.first?.id, item.id)

        store2.bind(userID: "bob")
        XCTAssertTrue(store2.items.isEmpty)
    }

    func testClearForSignOutClearsMemoryNotDisk() throws {
        let cache = RecordingPinnedCache()
        let store = PinnedItemsStore(cache: cache)
        store.bind(userID: "u")
        store.pin(.likedSongs(ownerDisplay: "You", artworkURL: nil))
        store.clearForSignOut()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNil(store.boundUserID)
        XCTAssertEqual(try cache.loadPinnedItems(userID: "u").count, 1)
    }

    func testMarkStale() {
        let cache = RecordingPinnedCache()
        let store = PinnedItemsStore(cache: cache)
        store.bind(userID: "u")
        let p = PinnedItem.playlist(
            SpotifyPlaylistSummary(id: "x", name: "X", description: nil, ownerName: "o", imageURL: nil, trackCount: 0, isPublic: nil, isCollaborative: false, snapshotID: "s")
        )
        store.pin(p)
        store.markStale(id: p.id, true)
        XCTAssertTrue(store.items.first?.isStale == true)
    }

    func testLibrarySidebarOrderNormalizesMissingSpecialRowsAndDropsUnknownPins() {
        let existing = [
            LibrarySidebarOrder.pinnedToken(for: "p2"),
            "orphan",
            LibrarySidebarOrder.homeToken
        ]
        let normalized = LibrarySidebarOrder.normalizedOrder(
            existing: existing,
            pinnedItemIDs: ["p1", "p2"]
        )
        XCTAssertEqual(
            normalized,
            [
                LibrarySidebarOrder.pinnedToken(for: "p2"),
                LibrarySidebarOrder.homeToken,
                LibrarySidebarOrder.likedSongsToken,
                LibrarySidebarOrder.pinnedToken(for: "p1")
            ]
        )
    }

    func testLibrarySidebarOrderDefaultsPinnedFirstOnInitialMigrationOrder() {
        let existing = [LibrarySidebarOrder.homeToken, LibrarySidebarOrder.likedSongsToken]
        let normalized = LibrarySidebarOrder.normalizedOrder(
            existing: existing,
            pinnedItemIDs: ["p1", "p2"]
        )
        XCTAssertEqual(
            normalized,
            [
                LibrarySidebarOrder.pinnedToken(for: "p1"),
                LibrarySidebarOrder.pinnedToken(for: "p2"),
                LibrarySidebarOrder.homeToken,
                LibrarySidebarOrder.likedSongsToken
            ]
        )
    }

    func testLibrarySidebarOrderPinnedInsertionIndexIgnoresSpecialRows() {
        let order = [
            LibrarySidebarOrder.homeToken,
            LibrarySidebarOrder.pinnedToken(for: "a"),
            LibrarySidebarOrder.likedSongsToken,
            LibrarySidebarOrder.pinnedToken(for: "b")
        ]
        let insertion = LibrarySidebarOrder.pinnedInsertionIndex(
            order: order,
            movingPinnedToken: nil,
            toInsertionIndex: 3
        )
        XCTAssertEqual(insertion, 1, "Only pinned rows before insertion should count.")
    }

    func testLibrarySidebarOrderPinnedInsertionIndexExcludesDraggedPinnedRow() {
        let order = [
            LibrarySidebarOrder.homeToken,
            LibrarySidebarOrder.pinnedToken(for: "a"),
            LibrarySidebarOrder.likedSongsToken,
            LibrarySidebarOrder.pinnedToken(for: "b")
        ]
        let insertion = LibrarySidebarOrder.pinnedInsertionIndex(
            order: order,
            movingPinnedToken: LibrarySidebarOrder.pinnedToken(for: "a"),
            toInsertionIndex: 4
        )
        XCTAssertEqual(insertion, 1, "Dragged source should be removed before counting.")
    }

    func testLibrarySidebarOrderMovedReturnsOriginalWhenTokenMissing() {
        let order = [
            LibrarySidebarOrder.homeToken,
            LibrarySidebarOrder.likedSongsToken
        ]
        let moved = LibrarySidebarOrder.moved(
            order: order,
            movingToken: LibrarySidebarOrder.pinnedToken(for: "missing"),
            toInsertionIndex: 0
        )
        XCTAssertEqual(moved, order)
    }

    func testPinnedDragPreviewStateClearsOnEndDrag() {
        let state = PinnedDragPreviewState(activeItem: nil)
        let item = PinnedItem.artist(
            SpotifyArtist(id: "artist-id", name: "Artist", imageURL: nil, uri: "spotify:artist:artist-id")
        )
        state.beginDrag(item: item)
        XCTAssertEqual(state.activeItem?.id, item.id)
        state.endDrag()
        XCTAssertNil(state.activeItem)
    }
}
