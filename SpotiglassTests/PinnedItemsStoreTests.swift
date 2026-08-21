import XCTest
import UniformTypeIdentifiers
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
                ownerID: "test-owner",
                ownerName: "o",
                imageURL: nil,
                trackCount: 0,
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
            SpotifyPlaylistSummary(id: "a", name: "A",
                ownerID: "test-owner", ownerName: "o", imageURL: nil, trackCount: 0, snapshotID: "1")
        )
        let b = PinnedItem.playlist(
            SpotifyPlaylistSummary(id: "b", name: "B",
                ownerID: "test-owner", ownerName: "o", imageURL: nil, trackCount: 0, snapshotID: "2")
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
            SpotifyPlaylistSummary(id: "a", name: "A",
                ownerID: "test-owner", ownerName: "o", imageURL: nil, trackCount: 0, snapshotID: "1")
        )
        let b = PinnedItem.playlist(
            SpotifyPlaylistSummary(id: "b", name: "B",
                ownerID: "test-owner", ownerName: "o", imageURL: nil, trackCount: 0, snapshotID: "2")
        )
        let c = PinnedItem.playlist(
            SpotifyPlaylistSummary(id: "c", name: "C",
                ownerID: "test-owner", ownerName: "o", imageURL: nil, trackCount: 0, snapshotID: "3")
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
            SpotifyPlaylistSummary(id: "a", name: "A",
                ownerID: "test-owner", ownerName: "o", imageURL: nil, trackCount: 0, snapshotID: "1")
        )
        let b = PinnedItem.playlist(
            SpotifyPlaylistSummary(id: "b", name: "B",
                ownerID: "test-owner", ownerName: "o", imageURL: nil, trackCount: 0, snapshotID: "2")
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
            SpotifyPlaylistSummary(id: "x", name: "X",
                ownerID: "test-owner", ownerName: "o", imageURL: nil, trackCount: 0, snapshotID: "s")
        )
        store.pin(p)
        store.markStale(id: p.id, true)
        XCTAssertTrue(store.items.first?.isStale == true)
    }

    func testMarkStaleIgnoresUnknownIDAndCanClearStaleFlag() {
        let cache = RecordingPinnedCache()
        let store = PinnedItemsStore(cache: cache)
        store.bind(userID: "u")
        let p = PinnedItem.playlist(
            SpotifyPlaylistSummary(id: "x", name: "X",
                ownerID: "test-owner", ownerName: "o", imageURL: nil, trackCount: 0, snapshotID: "s")
        )
        store.pin(p)
        store.markStale(id: "missing", true)
        XCTAssertEqual(store.items.first?.isStale, false)
        store.markStale(id: p.id, true)
        XCTAssertEqual(store.items.first?.isStale, true)
        store.markStale(id: p.id, false)
        XCTAssertEqual(store.items.first?.isStale, false)
    }

    func testBindSwitchesAccountsWithoutLeakingPins() {
        let cache = RecordingPinnedCache()
        let store = PinnedItemsStore(cache: cache)
        let alicePlaylist = PinnedItem.playlist(
            SpotifyPlaylistSummary(id: "alice-playlist", name: "Alice",
                ownerID: "test-owner", ownerName: "Alice", imageURL: nil, trackCount: 0, snapshotID: "a")
        )
        let bobArtist = PinnedItem.artist(
            SpotifyArtist(id: "bob-artist", name: "Bob", imageURL: nil, uri: "spotify:artist:bob-artist")
        )

        store.bind(userID: "alice")
        store.pin(alicePlaylist)
        XCTAssertEqual(store.items.map(\.id), [alicePlaylist.id])

        store.bind(userID: "bob")
        XCTAssertTrue(store.items.isEmpty)
        store.pin(bobArtist)
        XCTAssertEqual(store.items.map(\.id), [bobArtist.id])

        store.bind(userID: "alice")
        XCTAssertEqual(store.items.map(\.id), [alicePlaylist.id])
    }

    func testStaleBindingCannotReinstallPinsAfterAccountTransition() {
        let cache = RecordingPinnedCache()
        let store = PinnedItemsStore(cache: cache)
        let alicePlaylist = PinnedItem.playlist(
            SpotifyPlaylistSummary(id: "alice-playlist", name: "Alice",
                ownerID: "test-owner", ownerName: "Alice", imageURL: nil, trackCount: 0, snapshotID: "a")
        )
        store.bind(userID: "alice")
        store.pin(alicePlaylist)
        let staleGeneration = store.bindingGeneration

        store.clearForSignOut()
        store.bind(userID: "alice", bindingGeneration: staleGeneration)

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNil(store.boundUserID)
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
        // New pins join the end of the pins group so a trailing Home stays last.
        XCTAssertEqual(
            normalized,
            [
                LibrarySidebarOrder.pinnedToken(for: "p2"),
                LibrarySidebarOrder.pinnedToken(for: "p1"),
                LibrarySidebarOrder.homeToken
            ]
        )
    }

    func testLibrarySidebarOrderDefaultsPinnedFirstOnInitialMigrationOrder() {
        let existing = [LibrarySidebarOrder.homeToken, "library.likedSongs"]
        let normalized = LibrarySidebarOrder.normalizedOrder(
            existing: existing,
            pinnedItemIDs: ["p1", "p2"]
        )
        XCTAssertEqual(
            normalized,
            [
                LibrarySidebarOrder.pinnedToken(for: "p1"),
                LibrarySidebarOrder.pinnedToken(for: "p2"),
                LibrarySidebarOrder.homeToken
            ]
        )
    }

    func testApplyOrderReordersItemsToMatchVisibleRowOrder() {
        let cache = RecordingPinnedCache()
        let store = PinnedItemsStore(cache: cache)
        store.bind(userID: "u1")
        let a = PinnedItem.playlist(PlaylistBrowsingTestFixtures.playlist(id: "a", name: "A"))
        let b = PinnedItem.playlist(PlaylistBrowsingTestFixtures.playlist(id: "b", name: "B"))
        let c = PinnedItem.playlist(PlaylistBrowsingTestFixtures.playlist(id: "c", name: "C"))
        store.pin(a)
        store.pin(b)
        store.pin(c)

        store.applyOrder([c.id, a.id, b.id])
        XCTAssertEqual(store.items.map(\.id), [c.id, a.id, b.id])
    }

    func testApplyOrderKeepsUnlistedItemsAndIgnoresUnknownIDs() {
        let cache = RecordingPinnedCache()
        let store = PinnedItemsStore(cache: cache)
        store.bind(userID: "u1")
        let a = PinnedItem.playlist(PlaylistBrowsingTestFixtures.playlist(id: "a", name: "A"))
        let b = PinnedItem.playlist(PlaylistBrowsingTestFixtures.playlist(id: "b", name: "B"))
        store.pin(a)
        store.pin(b)

        store.applyOrder([b.id, "unknown-id"])
        XCTAssertEqual(store.items.map(\.id), [b.id, a.id], "Unlisted pins keep their relative order at the end; unknown IDs are ignored.")
    }

    /// Locks the `UTType.spotiglassPinnedItem` JSON wire format used by
    /// drag-to-pin (`.draggable` sources, `dropDestination` sink).
    func testPinnedTransferCodableRoundTripAndUnpin() throws {
        let cache = RecordingPinnedCache()
        let store = PinnedItemsStore(cache: cache)
        store.bind(userID: "u1")
        let playlist = PinnedItem.playlist(
            SpotifyPlaylistSummary(
                id: "p1",
                name: "A",
                ownerID: "test-owner",
                ownerName: "o",
                imageURL: nil,
                trackCount: 0,
                snapshotID: "s"
            )
        )
        store.pin(playlist)

        let transfer = PinnedItemTransfer(item: playlist)
        let data = try JSONEncoder().encode(transfer)
        let decoded = try JSONDecoder().decode(PinnedItemTransfer.self, from: data)
        XCTAssertEqual(decoded, transfer)
        XCTAssertEqual(decoded.item.id, playlist.id)

        store.unpin(id: decoded.item.id)
        XCTAssertTrue(store.items.isEmpty)
    }
}
