import XCTest
@testable import Spotiglass

final class SpotifyAPIClientCurrentUserProfileTests: XCTestCase {
    func testCurrentUserDecodingMapsMissingProductToUnknown() async throws {
        let httpClient = QueueHTTPClient([
            .json("""
            {
              "id": "user-1",
              "display_name": "Isaac",
              "images": [{ "url": "https://example.com/64.png", "height": 64, "width": 64 }],
              "country": "NL"
            }
            """)
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let profile = try await client.currentUserProfile()

        XCTAssertEqual(profile.id, "user-1")
        XCTAssertEqual(profile.displayName, "Isaac")
        XCTAssertEqual(profile.country, "NL")
    }

    func testCurrentUserDecodingToleratesMissingNullableFields() async throws {
        let httpClient = QueueHTTPClient([
            .json("""
            {
              "id": "user-1"
            }
            """)
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let profile = try await client.currentUserProfile()

        XCTAssertEqual(profile.id, "user-1")
        XCTAssertNil(profile.displayName)
        XCTAssertNil(profile.country)
    }

    func testCurrentUserProfileBypassesSharedCacheAfterAccountTransition() async throws {
        let cache = SpotifyGETResponseCache(diskCache: nil)
        let request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me")!)
        let key = try XCTUnwrap(SpotifyGETResponseCachePolicy.normalizedCacheKey(for: request))
        cache.store(body: Data("""
        { "id": "account-a", "display_name": "Account A", "images": [] }
        """.utf8), cacheKey: key, ttl: 300)
        let httpClient = QueueHTTPClient([
            .json("""
            {
              "id": "account-b",
              "display_name": "Account B",
              "images": []
            }
            """)
        ])
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"),
            httpClient: httpClient,
            getResponseCache: cache
        )

        let profile = try await client.currentUserProfile()

        XCTAssertEqual(profile.id, "account-b")
        XCTAssertEqual(httpClient.requests.count, 1)
    }
}
