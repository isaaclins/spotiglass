import XCTest
@testable import Spotiglass

final class SpotifyGETResponseCacheTests: XCTestCase {
    func testCachePolicyTTLAndShouldCache() {
        XCTAssertFalse(SpotifyGETResponseCachePolicy.shouldCache(URLRequest(url: URL(string: "https://api.spotify.com/v1/me/playlists")!)))
        XCTAssertFalse(SpotifyGETResponseCachePolicy.shouldCache(URLRequest(url: URL(string: "https://api.spotify.com/v1/me")!)))
        XCTAssertNil(SpotifyGETResponseCachePolicy.ttl(for: URL(string: "https://api.spotify.com/v1/me")!))
        XCTAssertEqual(SpotifyGETResponseCachePolicy.ttl(for: URL(string: "https://api.spotify.com/v1/search?q=x")!), 90)
        XCTAssertEqual(
            SpotifyGETResponseCachePolicy.ttl(for: URL(string: "https://api.spotify.com/v1/artists/ar1")!),
            900
        )
        XCTAssertEqual(
            SpotifyGETResponseCachePolicy.ttl(for: URL(string: "https://api.spotify.com/v1/albums/al1/tracks")!),
            600
        )
        XCTAssertEqual(
            SpotifyGETResponseCachePolicy.ttl(for: URL(string: "https://api.spotify.com/v1/foo")!),
            120
        )
    }

    func testCurrentUserProfileIsNeverReusedAcrossAccountTransitions() {
        let request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me")!)

        XCTAssertFalse(SpotifyGETResponseCachePolicy.shouldCache(request))
        XCTAssertNil(SpotifyGETResponseCachePolicy.ttl(for: request.url!))
    }

    func testNormalizedCacheKeyNormalizesSearchAndSortsQueryItems() {
        let search = URLRequest(url: URL(string: "https://api.spotify.com/v1/search?q=Hello%20World&type=track")!)
        let searchKey = SpotifyGETResponseCachePolicy.normalizedCacheKey(for: search)
        XCTAssertTrue(searchKey?.contains("q=hello%20world") == true || searchKey?.contains("q=hello world") == true)
    }

    func testMemoryLRUEvictsOldestEntry() {
        let cache = SpotifyGETResponseCache(diskCache: nil, maxMemoryEntries: 2)
        cache.store(body: Data([1]), cacheKey: "first", ttl: 120)
        cache.store(body: Data([2]), cacheKey: "second", ttl: 120)
        cache.store(body: Data([3]), cacheKey: "third", ttl: 120)

        XCTAssertNil(cache.cachedEntry(forCacheKey: "first", allowExpired: true))
        XCTAssertEqual(cache.cachedEntry(forCacheKey: "third", allowExpired: false)?.data, Data([3]))
    }

    func testDiskBackedCacheHydratesMemoryOnMiss() throws {
        let root = spotiglassTestsTemporaryDirectory()
        let disk = try SpotifyLocalCache(rootDirectory: root)
        let writer = SpotifyGETResponseCache(diskCache: disk)
        writer.store(body: Data("payload".utf8), cacheKey: "artist:ar1", ttl: 300)

        let reader = SpotifyGETResponseCache(diskCache: disk)
        let hit = reader.cachedEntry(forCacheKey: "artist:ar1", allowExpired: false)
        XCTAssertEqual(hit?.data, Data("payload".utf8))
        XCTAssertEqual(hit?.isExpired, false)
    }

    func testExpiredEntryHiddenUnlessAllowed() {
        let cache = SpotifyGETResponseCache(diskCache: nil)
        cache.store(body: Data([0]), cacheKey: "exp", ttl: 0)
        XCTAssertNil(cache.cachedEntry(forCacheKey: "exp", allowExpired: false))
        XCTAssertNotNil(cache.cachedEntry(forCacheKey: "exp", allowExpired: true)?.data)
    }

    // MARK: - Bounds (#381)

    func testPendingWritesStayBoundedWhenResponsesNeverArrive() {
        let cache = SpotifyGETResponseCache(diskCache: nil, maxPendingWrites: 8)
        var ownerships: [SpotifyGETResponseCacheWriteOwnership] = []
        // Every distinct search starts a write; these requests all failed before storing.
        for index in 0 ..< 500 {
            ownerships.append(cache.beginWrite(forCacheKey: "search:\(index)"))
        }

        XCTAssertLessThanOrEqual(cache.pendingWriteCountForTesting, 8)
        // The newest request can still store its response; a long-dropped one can't.
        XCTAssertTrue(cache.store(body: Data([1]), cacheKey: "search:499", ttl: 90, ownership: ownerships[499]))
        XCTAssertFalse(cache.store(body: Data([2]), cacheKey: "search:0", ttl: 90, ownership: ownerships[0]))
        XCTAssertNil(cache.cachedEntry(forCacheKey: "search:0", allowExpired: true))
    }

    func testStoredResponseEndsItsPendingWrite() {
        let cache = SpotifyGETResponseCache(diskCache: nil)
        for index in 0 ..< 300 {
            cache.store(body: Data([UInt8(index % 256)]), cacheKey: "search:\(index)", ttl: 90)
        }
        XCTAssertEqual(cache.pendingWriteCountForTesting, 0)
    }

    func testOlderWriteStillCannotOverwriteNewerOneAfterTheNewerOneStored() {
        let cache = SpotifyGETResponseCache(diskCache: nil)
        let older = cache.beginWrite(forCacheKey: "artist:ar1")
        let newer = cache.beginWrite(forCacheKey: "artist:ar1")
        XCTAssertTrue(cache.store(body: Data("new".utf8), cacheKey: "artist:ar1", ttl: 900, ownership: newer))
        XCTAssertFalse(cache.store(body: Data("old".utf8), cacheKey: "artist:ar1", ttl: 900, ownership: older))
        XCTAssertEqual(cache.cachedEntry(forCacheKey: "artist:ar1", allowExpired: false)?.data, Data("new".utf8))
    }

    func testDiskWritesPruneExpiredResponseFilesAtMostOncePerInterval() throws {
        let root = spotiglassTestsTemporaryDirectory()
        let disk = try SpotifyLocalCache(rootDirectory: root)
        let directory = root.appendingPathComponent("get_responses", isDirectory: true)
        let clock = TestClock(Date())
        let cache = SpotifyGETResponseCache(diskCache: disk, now: { clock.now })
        let pastRetention = clock.now.addingTimeInterval(-SpotifyLocalCache.getResponseRetention - 60)

        // A search from last month left on disk by an earlier launch.
        try disk.saveGETResponse(digest: "last-month", body: Data([1]), ttl: 90)
        try FileManager.default.setAttributes([.modificationDate: pastRetention], ofItemAtPath: directory.appendingPathComponent("last-month.json").path)

        cache.store(body: Data([2]), cacheKey: "search:today", ttl: 90)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("last-month.json").path))
        XCTAssertEqual(cache.cachedEntry(forCacheKey: "search:today", allowExpired: false)?.data, Data([2]))

        // Within the interval a write doesn't list the directory again...
        try disk.saveGETResponse(digest: "also-old", body: Data([3]), ttl: 90)
        try FileManager.default.setAttributes([.modificationDate: pastRetention], ofItemAtPath: directory.appendingPathComponent("also-old.json").path)
        cache.store(body: Data([4]), cacheKey: "search:later", ttl: 90)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("also-old.json").path))

        // ...and after it, the next write prunes.
        clock.now = clock.now.addingTimeInterval(SpotifyGETResponseCache.diskPruneInterval + 1)
        cache.store(body: Data([5]), cacheKey: "search:next", ttl: 90)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("also-old.json").path))

        // Responses this cache wrote still load in a new launch.
        let relaunched = SpotifyGETResponseCache(diskCache: disk)
        XCTAssertEqual(relaunched.cachedEntry(forCacheKey: "search:later", allowExpired: true)?.data, Data([4]))
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    var now: Date {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}
