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
}
