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
}
