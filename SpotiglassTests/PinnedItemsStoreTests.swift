import MusicKit
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

        // That cover only draws while the playlist is in the library. Search's catalog cover
        // loads on its own and takes its place; a later library cover doesn't undo that.
        store.fillMissingPlaylistArtwork(from: [MusicPlaylistSummary(
            id: "pl.u-ZmblDrrtVmXYkko", name: "Shared", ownerID: "me", ownerName: "You",
            imageURL: URL(string: "https://example.com/shared.jpg"), trackCount: nil, snapshotID: "applemusic"
        )])
        store.fillMissingPlaylistArtwork(from: [MusicPlaylistSummary(
            id: "pl.u-ZmblDrrtVmXYkko", name: "Shared", ownerID: "me", ownerName: "You",
            imageURL: URL(string: "musicKit://artwork/other"), trackCount: nil, snapshotID: "applemusic"
        )])
        XCTAssertEqual(store.items.first?.artworkURL?.absoluteString, "https://example.com/shared.jpg")
        XCTAssertEqual(cache.saved["u1"]?.first?.artworkURL?.absoluteString, "https://example.com/shared.jpg")
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

/// One Apple Music album pinned by its catalog ID (Home, a catalog artist page) and by its library
/// ID (Search, the command palette) is one pin (#487).
@MainActor
final class PinnedItemsAppleMusicIdentityTests: XCTestCase {
    private let account = AppleMusicBrowsingProvider.libraryUserID

    /// A saved album as `MusicLibraryRequest<Album>` lists it on macOS (shape captured from a real
    /// library): keyed by the Music app's persistent ID, with no catalog ID and no rating.
    private func libraryAlbum(
        persistentID: String, title: String, trackCount: Int = 12, releaseDate: String = "2017-01-13"
    ) throws -> Album {
        let json = """
        {"id":"\(persistentID)","type":"albums","attributes":{"name":"\(title)","artistName":"Bonobo",\
        "trackCount":\(trackCount),"releaseDate":"\(releaseDate)","playParams":{"musicKit_persistentID":"\(persistentID)",\
        "musicKit_databaseID":"785BA2D7E82AE547","kind":"album","id":"\(persistentID)","isLibrary":true}}}
        """
        return try JSONDecoder().decode(Album.self, from: Data(json.utf8))
    }

    /// The same album in the catalog, as Home and catalog artist pages get it.
    private func catalogAlbum(
        id: String, title: String, explicit: Bool? = nil, trackCount: Int = 12, releaseDate: String = "2017-01-13"
    ) throws -> Album {
        let rating = explicit.map { #","contentRating":"\#($0 ? "explicit" : "clean")""# } ?? ""
        let json = """
        {"id":"\(id)","type":"albums","attributes":{"name":"\(title)","artistName":"Bonobo","trackCount":\(trackCount)\
        \(rating),"releaseDate":"\(releaseDate)","playParams":{"id":"\(id)","kind":"album"}}}
        """
        return try JSONDecoder().decode(Album.self, from: Data(json.utf8))
    }

    /// What Home's Recently played pins: a catalog album known only by its ID, title and artist.
    private func homePin(_ catalogID: String, title: String) -> PinnedItem {
        .album(MusicAlbum(id: catalogID, name: title, artists: ["Bonobo"], imageURL: nil, uri: "applemusic:album:\(catalogID)"))
    }

    private func savedPin(_ persistentID: String, title: String) -> PinnedItem {
        .album(MusicAlbum(id: persistentID, name: title, artists: ["Bonobo"], imageURL: nil, uri: "applemusic:album:\(persistentID)"))
    }

    /// The resolver the app uses, with the library and the catalog replaced: `catalog` is what a
    /// catalog search finds, `pinned` what loading pinned albums by ID returns.
    private func aliases(
        registry: AppleMusicPinAliasRegistry = .shared,
        catalog: [Album] = [],
        library: [Album] = [],
        pinned: [Album] = [],
        searchFails: Bool = false,
        lookUp: @escaping @Sendable (PinnedItemKind, [String]) throws -> [String: String] = { _, _ in [:] },
        songReferences: AppleMusicSongReferenceRegistry = AppleMusicSongReferenceRegistry()
    ) -> AppleMusicPinAliases {
        struct Offline: Error {}
        return AppleMusicPinAliases(
            registry: registry,
            // Every stand-in answers on the main actor, like the store and the resolver, so all
            // the work a pin starts is main-actor steps that `settle()` can run to the end.
            lookUp: { @MainActor kind, ids in try lookUp(kind, ids) },
            albums: { @MainActor ids in pinned.filter { ids.contains($0.id.rawValue) } },
            searchAlbums: { @MainActor _ in
                if searchFails { throw Offline() }
                return AppleMusicAlbumSearch(catalog: catalog, library: library)
            },
            songReferences: songReferences
        )
    }

    /// Waits until `condition` holds, however long a busy machine takes (#503).
    private func waitUntil(_ condition: () -> Bool) async {
        while !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Runs every lookup, search and merge the store has queued to its end, for checks that
    /// nothing changed. The store, the resolver and the stand-in library all run on the main
    /// actor, so that work is a chain of main-actor steps; each pass runs one more step of it,
    /// however busy the machine, and the chain is far shorter than the passes.
    private func settle() async {
        for _ in 0..<20 {
            await withCheckedContinuation { done in
                DispatchQueue.main.async { done.resume() }
            }
        }
    }

    func testAlbumPinnedFromArtistPageAndFromSearchIsOnePin() async throws {
        let catalog = try catalogAlbum(id: "1225217151", title: "Migration 487a")
        let saved = try libraryAlbum(persistentID: "-2428838143274200674", title: "Migration 487a")
        let store = PinnedItemsStore(cache: RecordingPinnedCache(), aliases: aliases(catalog: [catalog], library: [saved]))
        store.bind(userID: account)

        // The artist page's album card, then the palette's search hit for the saved copy.
        let card = AppleMusicItemMapping.artistAlbum(catalog)
        XCTAssertTrue(store.pin(.album(card)))
        let searchHit = AppleMusicItemMapping.album(saved)

        await waitUntil { store.isPinned(spotifyID: searchHit.id, kind: .album) }
        XCTAssertTrue(store.isPinned(spotifyID: searchHit.id, kind: .album), "the saved copy shows as pinned")
        XCTAssertFalse(store.pin(.album(searchHit)), "pinning the saved copy adds nothing")
        XCTAssertEqual(store.items.map(\.id), ["album:1225217151"])

        store.unpin(id: PinnedItem.id(forKind: .album, spotifyID: searchHit.id))
        XCTAssertTrue(store.items.isEmpty, "unpinning the saved copy removes the catalog pin")

        // The other order: saved copy first, then the artist page.
        XCTAssertTrue(store.pin(.album(searchHit)))
        XCTAssertTrue(store.isPinned(spotifyID: card.id, kind: .album))
        XCTAssertFalse(store.pin(.album(card)))
        XCTAssertEqual(store.items.count, 1)
        store.unpin(id: "album:1225217151")
        XCTAssertTrue(store.items.isEmpty, "unpinning from the artist page removes the saved copy's pin")
    }

    func testAlbumPinnedFromHomeShowsAsPinnedInSearch() async throws {
        // Home knows the album only by its catalog ID: pinning loads it, which teaches its key.
        let catalog = try catalogAlbum(id: "1225217152", title: "Migration 487b")
        let saved = try libraryAlbum(persistentID: "-2318639096416010411", title: "Migration 487b")
        let store = PinnedItemsStore(
            cache: RecordingPinnedCache(), aliases: aliases(catalog: [catalog], library: [saved], pinned: [catalog])
        )
        store.bind(userID: account)
        XCTAssertTrue(store.pin(homePin("1225217152", title: "Migration 487b")))
        await waitUntil { store.items.first?.aliasIDs != nil }

        let searchHit = AppleMusicItemMapping.album(saved)
        await waitUntil { store.isPinned(spotifyID: searchHit.id, kind: .album) }
        XCTAssertTrue(store.isPinned(spotifyID: searchHit.id, kind: .album))
        XCTAssertFalse(store.pin(.album(searchHit)))
        store.unpin(id: PinnedItem.id(forKind: .album, spotifyID: searchHit.id))
        XCTAssertTrue(store.items.isEmpty)
    }

    func testASavedAlbumPairsWithTheReleaseOutOnItsDay() async throws {
        // As on a real library: the catalog has the explicit release (out 2022-07-15) and the
        // clean one (2022-07-14); the saved album has no rating, but came out on the 15th.
        let explicit = try catalogAlbum(id: "1225217153", title: "Migration 487c", explicit: true, trackCount: 10, releaseDate: "2022-07-15")
        let clean = try catalogAlbum(id: "1225217154", title: "Migration 487c", explicit: false, trackCount: 10, releaseDate: "2022-07-14")
        let saved = try libraryAlbum(persistentID: "-8203387087766707776", title: "Migration 487c", trackCount: 10, releaseDate: "2022-07-15")
        let store = PinnedItemsStore(
            cache: RecordingPinnedCache(), aliases: aliases(catalog: [explicit, clean], library: [saved])
        )
        store.bind(userID: account)

        XCTAssertTrue(store.pin(.album(AppleMusicItemMapping.artistAlbum(explicit))))
        let searchHit = AppleMusicItemMapping.album(saved)
        await waitUntil { store.isPinned(spotifyID: searchHit.id, kind: .album) }
        XCTAssertTrue(store.isPinned(spotifyID: searchHit.id, kind: .album), "the saved copy is the explicit release")
        XCTAssertFalse(store.isPinned(spotifyID: "1225217154", kind: .album), "the clean release is another album")
        XCTAssertTrue(store.pin(.album(AppleMusicItemMapping.artistAlbum(clean))))
        XCTAssertEqual(store.items.count, 2)
    }

    func testReleasesOutOnTheSameDayStayApart() async throws {
        let explicit = try catalogAlbum(id: "1225217155", title: "Migration 487q", explicit: true, releaseDate: "2022-07-15")
        let clean = try catalogAlbum(id: "1225217156", title: "Migration 487q", explicit: false, releaseDate: "2022-07-15")
        let saved = try libraryAlbum(persistentID: "-8203387087766707777", title: "Migration 487q", releaseDate: "2022-07-15")
        let store = PinnedItemsStore(
            cache: RecordingPinnedCache(), aliases: aliases(catalog: [explicit, clean], library: [saved])
        )
        store.bind(userID: account)
        XCTAssertTrue(store.pin(.album(AppleMusicItemMapping.artistAlbum(explicit))))
        let searchHit = AppleMusicItemMapping.album(saved)
        _ = store.isPinned(spotifyID: searchHit.id, kind: .album)
        await settle()
        XCTAssertFalse(store.isPinned(spotifyID: searchHit.id, kind: .album), "it can't be told which release it is")
        XCTAssertTrue(store.pin(.album(searchHit)))
    }

    func testDuplicatePinsFromBeforeMergeOnLaunchKeepingTheFirstPlace() async throws {
        let cache = RecordingPinnedCache()
        let other = PinnedItem.playlist(MusicPlaylistSummary(
            id: "p.Other", name: "Other", ownerID: account, ownerName: "You",
            imageURL: nil, trackCount: 3, snapshotID: "applemusic"
        ))
        // As saved before #487: the catalog copy, a playlist, then the library copy of the same album.
        cache.saved[account] = [homePin("1225217999", title: "Migration 487d"), other, savedPin("9177095676878600743", title: "Migration 487d")]
        let catalog = try catalogAlbum(id: "1225217999", title: "Migration 487d")
        let saved = try libraryAlbum(persistentID: "9177095676878600743", title: "Migration 487d")
        let store = PinnedItemsStore(cache: cache, aliases: aliases(
            registry: AppleMusicPinAliasRegistry(), catalog: [catalog], library: [saved], pinned: [catalog, saved]
        ))

        store.bind(userID: account)
        await waitUntil { store.items.count == 2 }

        XCTAssertEqual(store.items.map(\.id), ["album:1225217999", "playlist:p.Other"])
        XCTAssertEqual(cache.saved[account]?.map(\.id), ["album:1225217999", "playlist:p.Other"], "the merge is saved")
        XCTAssertTrue(store.isPinned(id: "album:9177095676878600743"))
        store.unpin(id: "album:9177095676878600743")
        XCTAssertEqual(store.items.map(\.id), ["playlist:p.Other"])
    }

    func testPinningDuringTheLaunchLookupStillMergesOldDuplicates() async throws {
        let cache = RecordingPinnedCache()
        cache.saved[account] = [homePin("1225217998", title: "Migration 487e"), savedPin("9177095676878600744", title: "Migration 487e")]
        let catalog = try catalogAlbum(id: "1225217998", title: "Migration 487e")
        let loaded = [catalog, try libraryAlbum(persistentID: "9177095676878600744", title: "Migration 487e")]
        let launchLookup = MockCallHold()
        let store = PinnedItemsStore(cache: cache, aliases: AppleMusicPinAliases(
            registry: AppleMusicPinAliasRegistry(), lookUp: { _, _ in [:] },
            albums: { ids in
                await launchLookup.pass()
                return loaded.filter { ids.contains($0.id.rawValue) }
            },
            searchAlbums: { _ in AppleMusicAlbumSearch(catalog: [catalog], library: loaded.filter { $0.id != catalog.id }) },
            songReferences: AppleMusicSongReferenceRegistry()
        ))
        store.bind(userID: account)
        let didStartLookup = await launchLookup.entered.wait(timeout: .seconds(mustHappenTimeout))
        XCTAssertTrue(didStartLookup, "binding should look up the pinned albums")
        // A pin while the launch lookup still runs.
        XCTAssertTrue(store.pin(.likedSongs(ownerDisplay: "You", artworkURL: nil), at: 0))
        launchLookup.release()
        await waitUntil { store.items.count == 2 }

        XCTAssertEqual(store.items.map(\.id), [PinnedItem.likedSongsID, "album:1225217998"])
    }

    func testTwoReleasesSharingANameAreNotMergedOnLaunch() async throws {
        // One pinned catalog release, and a saved album that is the other release of that name:
        // the catalog has two "Live" by this artist, so the saved one can't be paired with either.
        let cache = RecordingPinnedCache()
        cache.saved[account] = [homePin("1225217181", title: "Live 487i"), savedPin("9177095676878600745", title: "Live 487i")]
        let first = try catalogAlbum(id: "1225217181", title: "Live 487i")
        let second = try catalogAlbum(id: "1225217182", title: "Live 487i")
        let saved = try libraryAlbum(persistentID: "9177095676878600745", title: "Live 487i")
        let store = PinnedItemsStore(cache: cache, aliases: aliases(
            registry: AppleMusicPinAliasRegistry(), catalog: [first, second], library: [saved], pinned: [first, saved]
        ))
        store.bind(userID: account)
        await waitUntil { store.items.allSatisfy { $0.aliasIDs != nil } }

        XCTAssertEqual(store.items.map(\.id), ["album:1225217181", "album:9177095676878600745"])
        XCTAssertEqual(cache.saved[account]?.count, 2, "neither pin is deleted")
        XCTAssertEqual(store.items.map(\.aliasIDs), [[], []], "and no pair is saved")
        store.unpin(id: "album:9177095676878600745")
        XCTAssertEqual(store.items.map(\.id), ["album:1225217181"], "unpinning one leaves the other")
    }

    func testAFailedCatalogSearchMergesNothing() async throws {
        let cache = RecordingPinnedCache()
        cache.saved[account] = [homePin("1225217191", title: "Migration 487j"), savedPin("9177095676878600746", title: "Migration 487j")]
        let catalog = try catalogAlbum(id: "1225217191", title: "Migration 487j")
        let store = PinnedItemsStore(cache: cache, aliases: aliases(
            registry: AppleMusicPinAliasRegistry(), catalog: [catalog],
            pinned: [catalog, try libraryAlbum(persistentID: "9177095676878600746", title: "Migration 487j")],
            searchFails: true
        ))
        store.bind(userID: account)
        await settle()
        XCTAssertEqual(store.items.count, 2, "without the catalog's answer the copies stay apart")
    }

    func testDifferentAlbumsSharingANameStayTwoPins() async throws {
        // Two catalog releases with one title and artist (two "Greatest Hits") and one saved copy.
        let first = try catalogAlbum(id: "1225217161", title: "Greatest Hits 487g")
        let second = try catalogAlbum(id: "1225217162", title: "Greatest Hits 487g")
        let savedAlbum = try libraryAlbum(persistentID: "-2428838143274200675", title: "Greatest Hits 487g")
        let store = PinnedItemsStore(
            cache: RecordingPinnedCache(), aliases: aliases(catalog: [first, second], library: [savedAlbum])
        )
        store.bind(userID: account)
        let saved = AppleMusicItemMapping.album(savedAlbum)

        XCTAssertTrue(store.pin(.album(AppleMusicItemMapping.artistAlbum(first))))
        await settle()
        XCTAssertFalse(store.isPinned(spotifyID: "1225217162", kind: .album))
        XCTAssertFalse(store.isPinned(spotifyID: saved.id, kind: .album))
        XCTAssertTrue(store.pin(.album(AppleMusicItemMapping.artistAlbum(second))))
        XCTAssertTrue(store.pin(.album(saved)))
        await settle()
        XCTAssertEqual(store.items.count, 3)
        store.unpin(id: "album:1225217162")
        XCTAssertEqual(store.items.count, 2, "unpinning one release leaves the others")
    }

    func testPinnedAlbumsSharingANameSurviveLaunch() async throws {
        let cache = RecordingPinnedCache()
        cache.saved[account] = [homePin("1225217171", title: "Live 487h"), homePin("1225217172", title: "Live 487h")]
        let loaded = [try catalogAlbum(id: "1225217171", title: "Live 487h"), try catalogAlbum(id: "1225217172", title: "Live 487h")]
        let store = PinnedItemsStore(cache: cache, aliases: aliases(registry: AppleMusicPinAliasRegistry(), catalog: loaded, pinned: loaded))
        store.bind(userID: account)
        await waitUntil { store.items.allSatisfy { $0.aliasIDs != nil } }

        XCTAssertEqual(store.items.map(\.id), ["album:1225217171", "album:1225217172"])
        XCTAssertEqual(cache.saved[account]?.count, 2, "neither pin is deleted")
    }

    /// Pinned at launch: a catalog release, and a saved album with the same title and artist.
    private func launchWithSameNamePair(
        title: String, catalogTracks: Int, savedTracks: Int, extraSaved: Bool = false
    ) async throws -> (PinnedItemsStore, RecordingPinnedCache) {
        let cache = RecordingPinnedCache()
        cache.saved[account] = [homePin("1225217201", title: title), savedPin("9177095676878600747", title: title)]
        let catalog = try catalogAlbum(id: "1225217201", title: title, trackCount: catalogTracks)
        let saved = try libraryAlbum(persistentID: "9177095676878600747", title: title, trackCount: savedTracks)
        var library = [saved]
        if extraSaved { library.append(try libraryAlbum(persistentID: "9177095676878600748", title: title, trackCount: savedTracks)) }
        let store = PinnedItemsStore(cache: cache, aliases: aliases(
            registry: AppleMusicPinAliasRegistry(), catalog: [catalog], library: library, pinned: [catalog, saved]
        ))
        store.bind(userID: account)
        await waitUntil { store.items.allSatisfy { $0.aliasIDs != nil } }
        return (store, cache)
    }

    func testASavedAlbumWithOtherTracksIsNotTheCatalogRelease() async throws {
        // A saved album that isn't the catalog's release of that name (ripped, or pulled from
        // Apple Music): the one catalog release has 12 tracks, the saved album 9.
        let (store, cache) = try await launchWithSameNamePair(title: "Ripped 487l", catalogTracks: 12, savedTracks: 9)
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(cache.saved[account]?.count, 2, "neither pin is deleted")
    }

    func testTwoSavedAlbumsOfOneNameAreNotPaired() async throws {
        let (store, _) = try await launchWithSameNamePair(title: "Twice 487m", catalogTracks: 12, savedTracks: 12, extraSaved: true)
        XCTAssertEqual(store.items.count, 2, "the library has two albums under the key, so it's ambiguous")
    }

    func testTheSameTrackCountStillPairs() async throws {
        let (store, _) = try await launchWithSameNamePair(title: "Same 487n", catalogTracks: 12, savedTracks: 12)
        XCTAssertEqual(store.items.map(\.id), ["album:1225217201"])
    }

    func testASearchMissingThePinnedReleaseMergesNothing() async throws {
        // Pinned: catalog release C2 "Live" from Home, and a saved album that is really release C1.
        // The search only lists C1 (its 25 results missed C2), but the app knows C2 too.
        let cache = RecordingPinnedCache()
        cache.saved[account] = [homePin("1225219002", title: "Live 487o"), savedPin("9177095676878609001", title: "Live 487o")]
        let pinnedRelease = try catalogAlbum(id: "1225219002", title: "Live 487o")
        let otherRelease = try catalogAlbum(id: "1225219001", title: "Live 487o")
        let saved = try libraryAlbum(persistentID: "9177095676878609001", title: "Live 487o")
        let store = PinnedItemsStore(cache: cache, aliases: aliases(
            registry: AppleMusicPinAliasRegistry(), catalog: [otherRelease], library: [saved], pinned: [pinnedRelease, saved]
        ))
        store.bind(userID: account)
        await waitUntil { store.items.allSatisfy { $0.aliasIDs != nil } }

        XCTAssertEqual(store.items.map(\.id), ["album:1225219002", "album:9177095676878609001"])
        XCTAssertEqual(store.items.map(\.aliasIDs), [[], []], "no pair is saved")
        store.unpin(id: "album:9177095676878609001")
        XCTAssertEqual(store.items.map(\.id), ["album:1225219002"], "unpinning the saved album leaves the release")
    }

    func testTheOnlyReleaseFoundMustBeOutOnTheSavedAlbumsDay() async throws {
        // Pinned: catalog release C2 "Live" (2020) and a saved album that is really release C1
        // (2019), same track count. The search lists only C2: it isn't the saved album's release.
        let cache = RecordingPinnedCache()
        cache.saved[account] = [homePin("1225219102", title: "Live 487r"), savedPin("9177095676878609101", title: "Live 487r")]
        let pinnedRelease = try catalogAlbum(id: "1225219102", title: "Live 487r", releaseDate: "2020-05-01")
        let saved = try libraryAlbum(persistentID: "9177095676878609101", title: "Live 487r", releaseDate: "2019-03-01")
        let store = PinnedItemsStore(cache: cache, aliases: aliases(
            registry: AppleMusicPinAliasRegistry(), catalog: [pinnedRelease], library: [saved], pinned: [pinnedRelease, saved]
        ))
        store.bind(userID: account)
        await waitUntil { store.items.allSatisfy { $0.aliasIDs != nil } }

        XCTAssertEqual(store.items.map(\.id), ["album:1225219102", "album:9177095676878609101"], "neither pin is deleted")
    }

    func testSongDuplicatesMergeOnceAPlaylistRowTellsTheirIDs() async {
        // Saved before #487: a song pinned from Search (catalog ID) and from a library playlist row
        // (persistent ID). Launch can't tell; reading the playlist later does.
        let cache = RecordingPinnedCache()
        cache.saved[account] = [songPin("1600513004"), songPin("-4954366973876942251")]
        let registry = AppleMusicPinAliasRegistry()
        let references = AppleMusicSongReferenceRegistry()
        let store = PinnedItemsStore(cache: cache, aliases: aliases(registry: registry, songReferences: references))
        store.bind(userID: account)
        await settle()
        XCTAssertFalse(store.isPinned(id: "track:i.Other487"))
        XCTAssertEqual(store.items.count, 2)

        // The playlist is read: its row is remembered with the song's catalog ID and mapped.
        references.remember(AppleMusicSongReference(itemID: "-4954366973876942251", catalogID: "1600513004", isInLibrary: true))
        registry.register(kind: .track, itemID: "-4954366973876942251") { nil }
        // The playlist's other rows ask whether they're pinned.
        XCTAssertFalse(store.isPinned(id: "track:-4954366973876942252"))
        await waitUntil { store.items.count == 1 }

        XCTAssertEqual(store.items.map(\.id), ["track:1600513004"], "the first pin keeps its place")
        XCTAssertEqual(cache.saved[account]?.count, 1, "the merge is saved")
    }

    func testPinningASelectionLooksItUpOnce() async {
        // The command palette's Pin Selection pins row by row: one lookup for all of them.
        let resolver = BatchCountingResolver()
        let store = PinnedItemsStore(cache: RecordingPinnedCache(), aliases: resolver)
        store.bind(userID: account)
        for index in 0..<400 where !store.isPinned(id: "track:\(1_300_000_000 + index)") {
            store.pin(songPin(String(1_300_000_000 + index)))
        }
        await waitUntil { resolver.lookedUp == 400 }

        XCTAssertEqual(store.items.count, 400)
        XCTAssertEqual(resolver.lookups, 1)
        XCTAssertEqual(resolver.lookedUp, 400)
    }

    func testPlaylistInLibraryAndCatalogIsOnePin() {
        let registry = AppleMusicPinAliasRegistry()
        registry.register(kind: .playlist, itemID: "p.Lib487") { "pl.u-Cat487" }
        let store = PinnedItemsStore(cache: RecordingPinnedCache(), aliases: aliases(registry: registry))
        store.bind(userID: account)
        func playlist(_ id: String) -> PinnedItem {
            .playlist(MusicPlaylistSummary(
                id: id, name: "Chill", ownerID: "Apple Music", ownerName: "Apple Music",
                imageURL: nil, trackCount: 20, snapshotID: "applemusic"
            ))
        }

        XCTAssertTrue(store.pin(playlist("pl.u-Cat487")))
        XCTAssertFalse(store.pin(playlist("p.Lib487")))
        XCTAssertTrue(store.isPinned(spotifyID: "p.Lib487", kind: .playlist))
        store.unpin(id: "playlist:p.Lib487")
        XCTAssertTrue(store.items.isEmpty)
    }

    private func songPin(_ id: String) -> PinnedItem {
        PinnedItem(id: "track:\(id)", kind: .track, title: "Kerala", subtitle: "Bonobo", artworkURL: nil,
                   spotifyURI: "applemusic:song:\(id)", isStale: false)
    }

    func testSavedSongMatchesItsCatalogSong() throws {
        // Shape captured from a real library: a saved song carries its catalog ID.
        let json = #"{"id":"i.xrXvb5YUMXrPzzb","type":"library-songs","attributes":{"name":"Kerala","artistName":"Bonobo","playParams":{"kind":"song","musicKit_persistentID":"260349940219299207","id":"i.xrXvb5YUMXrPzzb","catalogId":"1677797558","musicKit_libraryID":"i.xrXvb5YUMXrPzzb","isLibrary":true}}}"#
        let saved = AppleMusicItemMapping.track(try JSONDecoder().decode(Song.self, from: Data(json.utf8)))
        let store = PinnedItemsStore(cache: RecordingPinnedCache(), aliases: aliases())
        store.bind(userID: account)
        XCTAssertTrue(store.pin(songPin("1677797558")))
        XCTAssertTrue(store.isPinned(spotifyID: saved.id, kind: .track))
        store.unpin(id: PinnedItem.id(forKind: .track, spotifyID: saved.id))
        XCTAssertTrue(store.items.isEmpty)
    }

    func testPlaylistRowSongMatchesItsCatalogSong() {
        // Rows of a library playlist are keyed by a persistent ID; the IDs the app worked out
        // for the row when it read the playlist (#401) tie it to the catalog song.
        let references = AppleMusicSongReferenceRegistry()
        references.remember(AppleMusicSongReference(
            itemID: "-4954366973876942250", catalogID: "1600513003", isInLibrary: true
        ))
        let store = PinnedItemsStore(cache: RecordingPinnedCache(), aliases: aliases(songReferences: references))
        store.bind(userID: account)

        XCTAssertTrue(store.pin(songPin("1600513003")))
        XCTAssertTrue(store.isPinned(spotifyID: "-4954366973876942250", kind: .track))
        XCTAssertFalse(store.pin(songPin("-4954366973876942250")))
        store.unpin(id: "track:-4954366973876942250")
        XCTAssertTrue(store.items.isEmpty)
    }

    func testFailedLookupIsAskedAgainNextLaunch() async {
        // Song pins: unlike album pins (loaded every launch), they are only looked up until checked.
        struct Offline: Error {}
        let cache = RecordingPinnedCache()
        cache.saved[account] = [songPin("1225217888"), songPin("1225217889")]
        let offline = PinnedItemsStore(cache: cache, aliases: aliases(
            registry: AppleMusicPinAliasRegistry(), lookUp: { _, _ in throw Offline() }
        ))
        offline.bind(userID: account)
        await settle()
        XCTAssertEqual(offline.items.map(\.aliasIDs), [nil, nil], "a failed lookup is not marked as checked")
        XCTAssertEqual(cache.saved[account]?.map(\.aliasIDs), [nil, nil], "so the next launch asks again")

        // The next launch: the library answers, one request for both songs.
        let asked = LockedCount()
        let online = PinnedItemsStore(cache: cache, aliases: aliases(
            registry: AppleMusicPinAliasRegistry(),
            lookUp: { _, ids in
                asked.add()
                return ids.contains("1225217888") ? ["1225217888": "i.Saved487"] : [:]
            }
        ))
        online.bind(userID: account)
        await waitUntil { online.items.allSatisfy { $0.aliasIDs != nil } }
        XCTAssertEqual(online.items.map(\.aliasIDs), [["track:i.Saved487"], []], "a lookup that found nothing counts as checked")
        XCTAssertEqual(asked.value, 1)
    }

    func testAMergedPinIsStaleOnlyWhenEveryCopyIs() async throws {
        let cache = RecordingPinnedCache()
        var gone = homePin("1225217211", title: "Gone 487p")
        gone.isStale = true
        cache.saved[account] = [gone, savedPin("9177095676878600749", title: "Gone 487p")]
        let catalog = try catalogAlbum(id: "1225217211", title: "Gone 487p")
        let saved = try libraryAlbum(persistentID: "9177095676878600749", title: "Gone 487p")
        let store = PinnedItemsStore(cache: cache, aliases: aliases(
            registry: AppleMusicPinAliasRegistry(), catalog: [catalog], library: [saved], pinned: [catalog, saved]
        ))
        store.bind(userID: account)
        await waitUntil { store.items.count == 1 }
        XCTAssertEqual(store.items.first?.isStale, false, "the saved copy still opens")
    }

    func testSpotifyRowsNeverAskTheResolver() {
        let resolver = CountingAliasResolver()
        let store = PinnedItemsStore(cache: RecordingPinnedCache(), aliases: resolver)
        store.bind(userID: "spotify-user")
        XCTAssertTrue(store.pin(.album(MusicAlbum(id: "4aawyAB9vmqN3uQ7FjRGTy", name: "Global Warming", artists: ["Pitbull"],
                                                  imageURL: nil, uri: "spotify:album:4aawyAB9vmqN3uQ7FjRGTy"))))

        XCTAssertTrue(store.isPinned(spotifyID: "4aawyAB9vmqN3uQ7FjRGTy", kind: .album))
        XCTAssertFalse(store.isPinned(spotifyID: "0sNOF9WDwhWunNAHPD3Baj", kind: .album))
        store.unpin(id: "album:0sNOF9WDwhWunNAHPD3Baj")
        XCTAssertEqual(resolver.asked, 0, "a Spotify list does the work it did before")
    }

    func testSpotifyPinsAreLeftExactlyAsTheyWere() async throws {
        let cache = RecordingPinnedCache()
        let pins = [
            PinnedItem.album(MusicAlbum(id: "4aawyAB9vmqN3uQ7FjRGTy", name: "Global Warming", artists: ["Pitbull"],
                                        imageURL: nil, uri: "spotify:album:4aawyAB9vmqN3uQ7FjRGTy")),
        ]
        cache.saved["spotify-user"] = pins
        let asked = LockedFlag()
        let store = PinnedItemsStore(cache: cache, aliases: AppleMusicPinAliases(
            registry: AppleMusicPinAliasRegistry(),
            lookUp: { @MainActor _, _ in asked.set(); return ["x": "y"] },
            albums: { @MainActor _ in asked.set(); return [] },
            searchAlbums: { @MainActor _ in asked.set(); return AppleMusicAlbumSearch(catalog: [], library: []) },
            songReferences: AppleMusicSongReferenceRegistry()
        ))
        store.bind(userID: "spotify-user")
        await settle()

        XCTAssertEqual(store.items, pins)
        XCTAssertEqual(cache.saved["spotify-user"], pins)
        XCTAssertFalse(asked.value, "no Apple Music lookup for a Spotify account")
        let saved = String(decoding: try JSONEncoder().encode(store.items), as: UTF8.self)
        XCTAssertFalse(saved.contains("aliasIDs"), "saved pins keep their old shape")
    }
}

@MainActor
private final class CountingAliasResolver: PinnedItemAliasResolving {
    private(set) var asked = 0
    func handles(userID: String) -> Bool { userID == AppleMusicBrowsingProvider.libraryUserID }
    var aliasesDidChange: (() -> Void)?
    var aliasGeneration: Int { 0 }
    func knownAliases(ofPinID pinID: String, checkingAlbum: Bool) -> Set<String> {
        asked += 1
        return []
    }
    func lookUpAliases(of pins: [PinnedItem], userID: String) async -> [String: Set<String>]? {
        asked += 1
        return nil
    }
}

@MainActor
private final class BatchCountingResolver: PinnedItemAliasResolving {
    private(set) var lookups = 0
    private(set) var lookedUp = 0
    var aliasesDidChange: (() -> Void)?
    var aliasGeneration: Int { 0 }
    func handles(userID: String) -> Bool { userID == AppleMusicBrowsingProvider.libraryUserID }
    func knownAliases(ofPinID pinID: String, checkingAlbum: Bool) -> Set<String> { [] }
    func lookUpAliases(of pins: [PinnedItem], userID: String) async -> [String: Set<String>]? {
        lookups += 1
        lookedUp += pins.count
        return Dictionary(uniqueKeysWithValues: pins.map { ($0.id, []) })
    }
}

private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var value: Bool { lock.withLock { raised } }
    func set() { lock.withLock { raised = true } }
}
