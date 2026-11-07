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

    // MARK: - Library continuation index

    func testLibraryContinuationIndexRoundTripsAndRespectsAge() throws {
        let (cache, _) = try makeCache()
        let track = MusicTrack(
            id: "t1",
            name: "Track",
            artists: ["Artist"],
            albumArtworkURL: nil,
            durationMilliseconds: 1_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "spotify:track:t1"
        )
        let library = LibraryContinuationLibrary(savedTracks: [track])
        try cache.saveLibraryContinuationIndex(library, cachedAt: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(
            try cache.loadLibraryContinuationIndex(
                now: Date(timeIntervalSince1970: 1_100),
                maxAge: 200
            ),
            library
        )
        XCTAssertNil(
            try cache.loadLibraryContinuationIndex(
                now: Date(timeIntervalSince1970: 1_300),
                maxAge: 200
            )
        )
        XCTAssertEqual(try cache.loadLibraryContinuationIndexIgnoringAge(), library)
        try cache.invalidateLibraryContinuationIndex()
        XCTAssertNil(try cache.loadLibraryContinuationIndexIgnoringAge())
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
        XCTAssertNil(try cache.loadGETResponseRecord(
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

    // MARK: - GET response bounds (#381)

    private func setModificationDate(_ date: Date, forFileAt url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func getResponseFiles(in root: URL) -> [String] {
        let directory = root.appendingPathComponent("get_responses", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    func testPruneGETResponsesDeletesFilesPastRetentionAndKeepsRecentOnes() throws {
        let (cache, root) = try makeCache()
        let now = Date()
        for digest in ["old-search", "old-artist", "recent"] {
            try cache.saveGETResponse(digest: digest, body: Data(digest.utf8), ttl: 90, cachedAt: now)
        }
        let directory = root.appendingPathComponent("get_responses", isDirectory: true)
        let pastRetention = now.addingTimeInterval(-SpotifyLocalCache.getResponseRetention - 60)
        try setModificationDate(pastRetention, forFileAt: directory.appendingPathComponent("old-search.json"))
        try setModificationDate(pastRetention, forFileAt: directory.appendingPathComponent("old-artist.json"))
        try cache.savePlaylists([PlaylistBrowsingTestFixtures.playlist(id: "P", name: "Mine")])

        cache.pruneGETResponses(now: now)

        XCTAssertEqual(getResponseFiles(in: root), ["recent.json"])
        XCTAssertNil(try cache.loadGETResponseRecord(digest: "old-search", now: now, allowExpired: true))
        // A kept response still loads, also as a stale fallback once its TTL has passed.
        let stale = try cache.loadGETResponseRecord(digest: "recent", now: now.addingTimeInterval(3_600), allowExpired: true)
        XCTAssertEqual(stale?.data, Data("recent".utf8))
        XCTAssertEqual(stale?.isExpired, true)
        // Pruning only touches the GET responses.
        XCTAssertEqual(try cache.loadPlaylistsBundle()?.playlists.map(\.id), ["P"])
    }

    func testPruneGETResponsesShrinksPastItsByteBoundOldestFirst() throws {
        let (cache, root) = try makeCache()
        let directory = root.appendingPathComponent("get_responses", isDirectory: true)
        let now = Date()
        let body = Data(repeating: 7, count: 1_000)
        for index in 0 ..< 40 {
            let digest = String(format: "search-%02d", index)
            try cache.saveGETResponse(digest: digest, body: body, ttl: 90, cachedAt: now)
            // search-00 was written first, search-39 last.
            try setModificationDate(now.addingTimeInterval(TimeInterval(index - 40)), forFileAt: directory.appendingPathComponent("\(digest).json"))
        }
        let sizeBefore = try directorySize(directory)
        let maxBytes = sizeBefore / 2
        XCTAssertGreaterThan(sizeBefore, maxBytes)

        cache.pruneGETResponses(now: now, maxBytes: maxBytes)

        XCTAssertLessThanOrEqual(try directorySize(directory), maxBytes * 3 / 4)
        let left = getResponseFiles(in: root)
        XCTAssertFalse(left.contains("search-00.json"))
        XCTAssertTrue(left.contains("search-39.json"))
        XCTAssertEqual(try cache.loadGETResponseRecord(digest: "search-39", now: now, allowExpired: false)?.data, body)
        // The newest files are the ones left.
        XCTAssertEqual(left, (40 - left.count ..< 40).map { String(format: "search-%02d.json", $0) })
    }

    private func directorySize(_ directory: URL) throws -> Int64 {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .reduce(Int64(0)) { $0 + Int64(try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
    }

    // MARK: - clear()

    func testClearRemovesPrivateAccountDataButPreservesCatalogResponsesAndPins() throws {
        let (cache, _) = try makeCache()
        let playlist = PlaylistBrowsingTestFixtures.playlist(id: "P", name: "Private")
        let pin = PinnedItem.playlist(playlist)
        try cache.savePlaylists([playlist], cachedAt: Date())
        try cache.saveTracks([], playlistID: "P", snapshotID: "S")
        try cache.saveLibraryContinuationIndex(
            LibraryContinuationLibrary(savedTracks: []),
            cachedAt: Date()
        )
        try cache.saveGETResponse(digest: "catalog", body: Data([1]), ttl: 60)
        try cache.savePinnedItems([pin], userID: "u")

        try cache.clearPrivateAccountData()

        XCTAssertNil(try cache.loadPlaylistsBundle())
        XCTAssertNil(try cache.loadTracksIgnoringAge(playlistID: "P", snapshotID: "S"))
        XCTAssertNil(try cache.loadLibraryContinuationIndexIgnoringAge())
        XCTAssertEqual(
            try cache.loadGETResponseRecord(digest: "catalog", allowExpired: true)?.data,
            Data([1])
        )
        XCTAssertEqual(try cache.loadPinnedItems(userID: "u"), [pin])
    }

    // MARK: - CachedPlaylistTracks.isValid TTL boundary

    func testCachedPlaylistTracksValidityBoundary() {
        let track = PlaylistBrowsingTestFixtures.track(id: "t")
        let cached = CachedPlaylistTracks(
            playlistID: "P", snapshotID: "S", tracks: [track], cachedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(cached.isValid(forPlaylist: "P", snapshotID: "S", now: Date(timeIntervalSince1970: 300), maxAge: 300))
        XCTAssertFalse(cached.isValid(forPlaylist: "P", snapshotID: "S", now: Date(timeIntervalSince1970: 301), maxAge: 300))
        XCTAssertFalse(cached.isValid(forPlaylist: "OTHER", snapshotID: "S"))
        XCTAssertFalse(cached.isValid(forPlaylist: "P", snapshotID: "OTHER"))
    }
}
