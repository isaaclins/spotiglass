import XCTest
@testable import Spotiglass

final class SpotifyAPIClientArtistsEndpointTests: XCTestCase {
    func testArtistEndpointsRejectEmptyID() async {
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"),
            httpClient: QueueHTTPClient([])
        )

        await XCTAssertThrowsSpotifyAPIError(
            try await client.artist(id: ""),
            .invalidRequest("Artist ID is required.")
        )
        await XCTAssertThrowsSpotifyAPIError(
            try await client.artistCached(id: ""),
            .invalidRequest("Artist ID is required.")
        )
        await XCTAssertThrowsSpotifyAPIError(
            try await client.artistTopTracks(id: "", market: nil),
            .invalidRequest("Artist ID is required.")
        )
        await XCTAssertThrowsSpotifyAPIError(
            try await client.artistAlbumsPage(id: ""),
            .invalidRequest("Artist ID is required.")
        )
        await XCTAssertThrowsSpotifyAPIError(
            try await client.artistAlbumsCached(id: ""),
            .invalidRequest("Artist ID is required.")
        )
    }

    func testArtistCachedDecodesAndReportsStaleFlag() async throws {
        let httpClient = QueueHTTPClient([
            .json("""
            {
              "id": "ar1",
              "name": "Cached Artist",
              "images": [],
              "followers": { "total": 1 },
              "genres": [],
              "uri": "spotify:artist:ar1"
            }
            """)
        ])
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"),
            httpClient: httpClient
        )

        let cached = try await client.artistCached(id: "ar1", cacheMode: .allowStale)

        XCTAssertEqual(cached.value.name, "Cached Artist")
        XCTAssertFalse(cached.isStale)
        XCTAssertEqual(httpClient.requests.first?.url?.path, "/v1/artists/ar1")
    }

    func testArtistAlbumsCachedClampsLimitAndMapsAlbums() async throws {
        let httpClient = QueueHTTPClient([
            .json("""
            {
              "items": [
                {
                  "id": "al1",
                  "name": "Album",
                  "release_date": "2020-01-01",
                  "total_tracks": 1,
                  "images": [],
                  "uri": "spotify:album:al1",
                  "album_group": "album"
                }
              ],
              "total": 1,
              "limit": 10,
              "offset": 0,
              "href": "https://api.spotify.com/v1/artists/ar1/albums",
              "next": null
            }
            """)
        ])
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"),
            httpClient: httpClient
        )

        let cached = try await client.artistAlbumsCached(id: "ar1", limit: 99, cacheMode: .freshOnly)

        XCTAssertEqual(cached.value.count, 1)
        XCTAssertEqual(cached.value.first?.id, "al1")
        let url = try XCTUnwrap(httpClient.requests.first?.url?.absoluteString)
        XCTAssertTrue(url.contains("limit=10"))
    }

    func testArtistAlbumsPageFollowsNextURL() async throws {
        let next = URL(string: "https://api.spotify.com/v1/artists/ar1/albums?offset=10&limit=10")!
        let httpClient = QueueHTTPClient([
            .json("""
            {
              "items": [],
              "total": 0,
              "limit": 10,
              "offset": 10,
              "href": "https://api.spotify.com/v1/artists/ar1/albums",
              "next": null
            }
            """)
        ])
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"),
            httpClient: httpClient
        )

        _ = try await client.artistAlbumsPage(id: "ar1", nextURL: next)

        XCTAssertEqual(httpClient.requests.first?.url, next)
    }

    func testArtistTopTracksDefaultsMarketToFromToken() async throws {
        let httpClient = QueueHTTPClient([.json(#"{"tracks":[]}"#)])
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"),
            httpClient: httpClient
        )

        _ = try await client.artistTopTracks(id: "ar1", market: nil)

        XCTAssertTrue(httpClient.requests.first?.url?.query?.contains("market=from_token") == true)
    }
}
