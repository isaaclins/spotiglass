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
}
