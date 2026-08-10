import XCTest

@testable import Spotiglass

final class SpotifyAPIClientSearchAndHTTPTests: XCTestCase {
    func testSearchClampsRequestedLimitToSpotifyMaximum() async throws {
        let httpClient = QueueHTTPClient([
            .json(
                """
                {
                  "tracks": { "items": [] },
                  "artists": { "items": [] },
                  "albums": { "items": [] },
                  "playlists": { "items": [] }
                }
                """)
        ])
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        _ = try await client.search(query: "kanye", limit: 999)

        XCTAssertEqual(httpClient.requests.count, 1)
        XCTAssertEqual(
            httpClient.requests[0].url?.absoluteString,
            "https://api.spotify.com/v1/search?q=kanye&type=track,artist,album,playlist&limit=10"
        )
    }

    func testRequestConstructionAddsAuthorizationAndQuery() throws {
        let client = SpotifyAPIClient(
            baseURL: URL(string: "https://api.spotify.com")!,
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "access-token"),
            httpClient: QueueHTTPClient([])
        )

        let request = try client.makeRequest(
            path: "/v1/me/playlists",
            queryItems: [URLQueryItem(name: "limit", value: "50")],
            accessToken: "access-token"
        )

        XCTAssertEqual(request.url?.absoluteString, "https://api.spotify.com/v1/me/playlists?limit=50")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }
}
