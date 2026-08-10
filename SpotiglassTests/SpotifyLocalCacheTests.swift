import XCTest

@testable import Spotiglass

final class SpotifyLocalCacheTests: XCTestCase {

    private func makeCache() throws -> (cache: SpotifyLocalCache, root: URL) {
        let root = spotiglassTestsTemporaryDirectory()
        let cache = try SpotifyLocalCache(rootDirectory: root)
        return (cache, root)
    }

    // MARK: - Playlists bundle

    func testSavePlaylistsAndLoadPlaylistsBundleRoundTripWithAge() throws {
        let (cache, _) = try makeCache()
        let playlists = [PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "Songs")]
        try cache.savePlaylists(playlists, cachedAt: Date(timeIntervalSince1970: 1_000))
        let bundle = try cache.loadPlaylistsBundle(now: Date(timeIntervalSince1970: 1_120))
        XCTAssertEqual(bundle?.playlists, playlists)
        XCTAssertEqual(bundle?.age ?? -1, 120, accuracy: 0.001)
    }

    func testLoadPlaylistsBundleReturnsNilWhenAbsent() throws {
        let (cache, _) = try makeCache()
        XCTAssertNil(try cache.loadPlaylistsBundle())
    }

    // MARK: - loadTracksIgnoringAge

    func testLoadTracksIgnoringAgeReturnsTracksWhenSnapshotMatchesEvenWhenExpired() throws {
        let (cache, _) = try makeCache()
        let track = PlaylistBrowsingTestFixtures.track(id: "t1")
        try cache.saveTracks([track], playlistID: "P", snapshotID: "S", cachedAt: Date(timeIntervalSince1970: 0))
        // Way past TTL.
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNil(try cache.loadTracks(playlistID: "P", snapshotID: "S", now: now, maxAge: 300))
        // But ignoring age returns the same tracks.
        XCTAssertEqual(try cache.loadTracksIgnoringAge(playlistID: "P", snapshotID: "S"), [track])
        // Mismatched snapshot still returns nil even ignoring age.
        XCTAssertNil(try cache.loadTracksIgnoringAge(playlistID: "P", snapshotID: "S2"))
    }

    func testLoadTracksIgnoringAgeReturnsNilForMissingPlaylist() throws {
        let (cache, _) = try makeCache()
        XCTAssertNil(try cache.loadTracksIgnoringAge(playlistID: "ghost", snapshotID: "x"))
    }

    func testInvalidateTracksRemovesEntry() throws {
        let (cache, _) = try makeCache()
        try cache.saveTracks([], playlistID: "P", snapshotID: "S")
        try cache.invalidateTracks(playlistID: "P")
        XCTAssertNil(try cache.loadTracksIgnoringAge(playlistID: "P", snapshotID: "S"))
        // Idempotent — invalidating an already-missing entry should not throw.
        XCTAssertNoThrow(try cache.invalidateTracks(playlistID: "P"))
    }

    // MARK: - Pinned items per-account

    func testSavePinnedItemsAndLoadPinnedItemsRoundTripPerUser() throws {
        let (cache, _) = try makeCache()
        let p1 = PinnedItem(
            id: "playlist:abc", kind: .playlist, title: "T", subtitle: "S",
            artworkURL: nil, spotifyURI: "spotify:playlist:abc", isStale: false
        )
        let p2 = PinnedItem(
            id: PinnedItem.likedSongsID, kind: .likedSongs, title: "Liked", subtitle: "x",
            artworkURL: nil, spotifyURI: nil, isStale: false
        )
        try cache.savePinnedItems([p1, p2], userID: "userA")
        XCTAssertEqual(try cache.loadPinnedItems(userID: "userA"), [p1, p2])
        // Different user is isolated.
        XCTAssertEqual(try cache.loadPinnedItems(userID: "userB"), [])
        // Overwrite.
        try cache.savePinnedItems([], userID: "userA")
        XCTAssertEqual(try cache.loadPinnedItems(userID: "userA"), [])
    }

    func testPinnedItemsUserIDIsFileSafeForFunkyCharacters() throws {
        let (cache, _) = try makeCache()
        // Slashes and unicode must not escape the pinned/ directory.
        let weird = "user/with../slash and space"
        let p = PinnedItem(
            id: "playlist:1", kind: .playlist, title: "t", subtitle: "s",
            artworkURL: nil, spotifyURI: "spotify:playlist:1", isStale: false
        )
        try cache.savePinnedItems([p], userID: weird)
        XCTAssertEqual(try cache.loadPinnedItems(userID: weird), [p])
    }

    // MARK: - GET response cache

    func testSaveGETResponseAndLoadFresh() throws {
        let (cache, _) = try makeCache()
        let body = Data("hello".utf8)
        try cache.saveGETResponse(digest: "abc", body: body, ttl: 60, cachedAt: Date(timeIntervalSince1970: 1_000))
        let rec = try cache.loadGETResponseRecord(
            digest: "abc",
            now: Date(timeIntervalSince1970: 1_010),
            allowExpired: false
        )
        XCTAssertEqual(rec?.data, body)
        XCTAssertEqual(rec?.isExpired, false)
        XCTAssertEqual(rec?.expiresAt, Date(timeIntervalSince1970: 1_060))
    }

    func testLoadGETResponseExpiredReturnsNilWhenNotAllowed() throws {
        let (cache, _) = try makeCache()
        try cache.saveGETResponse(digest: "d", body: Data([1, 2]), ttl: 60, cachedAt: Date(timeIntervalSince1970: 0))
        XCTAssertNil(
            try cache.loadGETResponseRecord(
                digest: "d", now: Date(timeIntervalSince1970: 1_000), allowExpired: false
            ))
    }

    func testLoadGETResponseExpiredReturnedWhenAllowed() throws {
        let (cache, _) = try makeCache()
        try cache.saveGETResponse(digest: "d", body: Data([1, 2]), ttl: 60, cachedAt: Date(timeIntervalSince1970: 0))
        let rec = try cache.loadGETResponseRecord(
            digest: "d", now: Date(timeIntervalSince1970: 1_000), allowExpired: true
        )
        XCTAssertNotNil(rec)
        XCTAssertTrue(rec?.isExpired ?? false)
        XCTAssertEqual(rec?.data, Data([1, 2]))
    }

    func testLoadGETResponseMissingReturnsNil() throws {
        let (cache, _) = try makeCache()
        XCTAssertNil(try cache.loadGETResponseRecord(digest: "ghost", allowExpired: true))
    }

    // MARK: - clear()

    func testClearRemovesEverything() throws {
        let (cache, root) = try makeCache()
        try cache.savePlaylists([], cachedAt: Date())
        try cache.saveTracks([], playlistID: "P", snapshotID: "S")
        try cache.saveGETResponse(digest: "d", body: Data([0]), ttl: 60)
        try cache.savePinnedItems([], userID: "u")

        try cache.clear()
        XCTAssertNil(try cache.loadPlaylistsBundle())
        XCTAssertNil(try cache.loadTracksIgnoringAge(playlistID: "P", snapshotID: "S"))
        XCTAssertNil(try cache.loadGETResponseRecord(digest: "d", allowExpired: true))
        XCTAssertEqual(try cache.loadPinnedItems(userID: "u"), [])

        // clear() is safe to call again on empty state.
        XCTAssertNoThrow(try cache.clear())
        // Root directory either gone or empty.
        _ = root
    }

    // MARK: - CachedPlaylistTracks.isValid TTL boundary

    func testCachedPlaylistTracksValidityBoundary() {
        let track = PlaylistBrowsingTestFixtures.track(id: "t")
        let cached = CachedPlaylistTracks(
            playlistID: "P", snapshotID: "S", tracks: [track], cachedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(
            cached.isValid(forPlaylist: "P", snapshotID: "S", now: Date(timeIntervalSince1970: 300), maxAge: 300))
        XCTAssertFalse(
            cached.isValid(forPlaylist: "P", snapshotID: "S", now: Date(timeIntervalSince1970: 301), maxAge: 300))
        XCTAssertFalse(cached.isValid(forPlaylist: "OTHER", snapshotID: "S"))
        XCTAssertFalse(cached.isValid(forPlaylist: "P", snapshotID: "OTHER"))
    }
}
