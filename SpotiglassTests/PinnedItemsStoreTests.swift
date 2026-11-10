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
    /// Pins made while Apple Music playlists without a picture of their own were listed
    /// without their cover (#444) saved no cover and kept the grey tile for good. The next
    /// listing gives them the cover their playlist has, saved for the next launch, and leaves
    /// every pin that already has one alone (#477).
    func testPlaylistPinsSavedWithoutACoverGetTheirPlaylistsCover() {
        let cache = RecordingPinnedCache()
        let store = PinnedItemsStore(cache: cache)
        store.bind(userID: "u1")
        func summary(_ id: String, _ url: String?) -> MusicPlaylistSummary {
            MusicPlaylistSummary(
                id: id, name: id, ownerID: "me", ownerName: "You",
                imageURL: url.flatMap(URL.init(string:)), trackCount: nil, snapshotID: "applemusic"
            )
        }
        store.pin(.playlist(summary("road", nil)))
        store.pin(.playlist(summary("mix", "https://example.com/old.jpg")))
        store.pin(.playlist(summary("gone", nil)))
        store.pin(.album(MusicAlbum(id: "road", name: "Road", artists: [], imageURL: nil, uri: "applemusic:album:road")))

        store.fillMissingPlaylistArtwork(from: [
            PlaylistRowViewModel(summary("road", "musicKit://artwork/road")),
            PlaylistRowViewModel(summary("mix", "https://example.com/new.jpg")),
        ])

        let artwork = store.items.map(\.artworkURL?.absoluteString)
        XCTAssertEqual(artwork, ["musicKit://artwork/road", "https://example.com/old.jpg", nil, nil])
        XCTAssertEqual(cache.saved["u1"]?.map(\.artworkURL?.absoluteString), artwork)
    }

    /// A shared Apple Music playlist pinned from Search is saved under its catalog ID
    /// (`pl.u-…`), which the library listing doesn't name its rows by: a search result that
    /// finds it gives the pin back its cover (#477).
    func testSharedPlaylistPinnedFromSearchGetsItsCoverFromASearchResult() {
        let cache = RecordingPinnedCache()
        let store = PinnedItemsStore(cache: cache)
        store.bind(userID: "u1")
        func summary(_ id: String, _ url: String?) -> MusicPlaylistSummary {
            MusicPlaylistSummary(
                id: id, name: "Shared", ownerID: "me", ownerName: "You",
                imageURL: url.flatMap(URL.init(string:)), trackCount: nil, snapshotID: "applemusic"
            )
        }
        store.pin(.playlist(summary("pl.u-ZmblDrrtVmXYkko", nil)))

        store.fillMissingPlaylistArtwork(from: [PlaylistRowViewModel(summary("46595082274209082", "musicKit://artwork/shared"))])
        XCTAssertNil(store.items.first?.artworkURL)

        store.fillMissingPlaylistArtwork(from: [summary("pl.u-ZmblDrrtVmXYkko", "https://example.com/shared.jpg")])
        XCTAssertEqual(store.items.first?.artworkURL?.absoluteString, "https://example.com/shared.jpg")
        XCTAssertEqual(cache.saved["u1"]?.first?.artworkURL?.absoluteString, "https://example.com/shared.jpg")
    }

    /// The pins can come in after the list: the account is bound once its lookup answers, and a
    /// service switch clears the pins and loads the other library's while its list is already
    /// on screen and isn't listed again. Those pins get the covers from the list on hand (#477).
    func testPinsLoadedAfterTheListGetTheirCoverFromIt() {
        let cache = RecordingPinnedCache()
        func summary(_ id: String, _ url: String?) -> MusicPlaylistSummary {
            MusicPlaylistSummary(
                id: id, name: id, ownerID: "me", ownerName: "You",
                imageURL: url.flatMap(URL.init(string:)), trackCount: nil, snapshotID: "applemusic"
            )
        }
        cache.saved["u1"] = [
            .playlist(summary("road", nil)),
            .playlist(summary("mix", "https://example.com/old.jpg")),
        ]
        let store = PinnedItemsStore(cache: cache)
        store.fillMissingPlaylistArtwork(from: [
            PlaylistRowViewModel(summary("road", "musicKit://artwork/road")),
            PlaylistRowViewModel(summary("mix", "https://example.com/new.jpg")),
        ])

        store.bind(userID: "u1")
        let expected: [String?] = ["musicKit://artwork/road", "https://example.com/old.jpg"]
        XCTAssertEqual(store.items.map(\.artworkURL?.absoluteString), expected)
        XCTAssertEqual(cache.saved["u1"]?.map(\.artworkURL?.absoluteString), expected)

        // A service switch: the pins are cleared and loaded again, the list stays as it was.
        store.clearForSignOut()
        cache.saved["u1"] = [.playlist(summary("road", nil))]
        store.bind(userID: "u1")
        XCTAssertEqual(store.items.first?.artworkURL?.absoluteString, "musicKit://artwork/road")
    }

    /// A pin no list names by its ID (a shared playlist pinned from Search, under its catalog
    /// ID) gets the cover the app knows for that pin from elsewhere (#477).
    func testPlaylistPinWithoutACoverGetsTheCoverKnownForItsID() {
        let cache = RecordingPinnedCache()
        let store = PinnedItemsStore(cache: cache) { pinID in
            pinID == "playlist:pl.u-ZmblDrrtVmXYkko" ? URL(string: "musicKit://artwork/shared") : nil
        }
        store.bind(userID: "u1")
        store.pin(.playlist(MusicPlaylistSummary(
            id: "pl.u-ZmblDrrtVmXYkko", name: "Shared", ownerID: "me", ownerName: "You",
            imageURL: nil, trackCount: nil, snapshotID: "applemusic"
        )))
        store.pin(.album(MusicAlbum(id: "pl.u-ZmblDrrtVmXYkko", name: "Road", artists: [], imageURL: nil, uri: "applemusic:album:x")))

        store.fillMissingPlaylistArtwork(from: [PlaylistRowViewModel(MusicPlaylistSummary(
            id: "46595082274209082", name: "Shared", ownerID: "me", ownerName: "You",
            imageURL: URL(string: "musicKit://artwork/library"), trackCount: nil, snapshotID: "applemusic"
        ))])

        XCTAssertEqual(store.items.map(\.artworkURL?.absoluteString), ["musicKit://artwork/shared", nil])
        XCTAssertEqual(cache.saved["u1"]?.first?.artworkURL?.absoluteString, "musicKit://artwork/shared")
    }

    func testPinDedupesSameId() {
        let cache = RecordingPinnedCache()
        let store = PinnedItemsStore(cache: cache)
        store.bind(userID: "u1")
        let playlist = PinnedItem.playlist(
            MusicPlaylistSummary(
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
            MusicPlaylistSummary(id: "a", name: "A",
                ownerID: "test-owner", ownerName: "o", imageURL: nil, trackCount: 0, snapshotID: "1")
        )
        let b = PinnedItem.playlist(
            MusicPlaylistSummary(id: "b", name: "B",
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
            MusicPlaylistSummary(id: "a", name: "A",
                ownerID: "test-owner", ownerName: "o", imageURL: nil, trackCount: 0, snapshotID: "1")
        )
        let b = PinnedItem.playlist(
            MusicPlaylistSummary(id: "b", name: "B",
                ownerID: "test-owner", ownerName: "o", imageURL: nil, trackCount: 0, snapshotID: "2")
        )
        let c = PinnedItem.playlist(
            MusicPlaylistSummary(id: "c", name: "C",
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
            MusicPlaylistSummary(id: "a", name: "A",
                ownerID: "test-owner", ownerName: "o", imageURL: nil, trackCount: 0, snapshotID: "1")
        )
        let b = PinnedItem.playlist(
            MusicPlaylistSummary(id: "b", name: "B",
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
            MusicArtist(id: "ar1", name: "Artist", imageURL: nil, uri: "spotify:artist:ar1")
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

    func testBindMigratesPositionQualifiedTrackPinToCanonicalIdentity() {
        let cache = RecordingPinnedCache()
        let legacy = PinnedItem(
            id: "track:track-real:7",
            kind: .track,
            title: "Same Song",
            subtitle: "Artist",
            artworkURL: nil,
            spotifyURI: "spotify:track:track-real",
            isStale: false
        )
        cache.saved["u"] = [legacy]
        let store = PinnedItemsStore(cache: cache)

        store.bind(userID: "u")

        XCTAssertEqual(store.items.map(\.id), ["track:track-real"])
        XCTAssertEqual(cache.saved["u"]?.map(\.id), ["track:track-real"])

        store.unpin(id: "track:track-real")
        XCTAssertTrue(store.items.isEmpty)
    }

    func testLegacyTrackPinJSONDecodesAndMigratesWhenBound() throws {
        let legacyJSON = """
        {
          "id": "track:track-real:7",
          "kind": "track",
          "title": "Same Song",
          "subtitle": "Artist",
          "artworkURL": null,
          "spotifyURI": "spotify:track:track-real",
          "isStale": false
        }
        """
        let legacy = try JSONDecoder().decode(PinnedItem.self, from: Data(legacyJSON.utf8))
        let cache = RecordingPinnedCache()
        cache.saved["u"] = [legacy]
        let store = PinnedItemsStore(cache: cache)

        store.bind(userID: "u")

        XCTAssertEqual(store.items.map(\.id), ["track:track-real"])
        XCTAssertEqual(cache.saved["u"]?.map(\.id), ["track:track-real"])
    }

    func testMarkStale() {
        let cache = RecordingPinnedCache()
        let store = PinnedItemsStore(cache: cache)
        store.bind(userID: "u")
        let p = PinnedItem.playlist(
            MusicPlaylistSummary(id: "x", name: "X",
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
            MusicPlaylistSummary(id: "x", name: "X",
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
            MusicPlaylistSummary(id: "alice-playlist", name: "Alice",
                ownerID: "test-owner", ownerName: "Alice", imageURL: nil, trackCount: 0, snapshotID: "a")
        )
        let bobArtist = PinnedItem.artist(
            MusicArtist(id: "bob-artist", name: "Bob", imageURL: nil, uri: "spotify:artist:bob-artist")
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
            MusicPlaylistSummary(id: "alice-playlist", name: "Alice",
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
            MusicPlaylistSummary(
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
