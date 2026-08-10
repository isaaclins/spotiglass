import XCTest

@testable import Spotiglass

final class SpotifyAPIClientPlaylistListPaginationTests: XCTestCase {
    func testPlaylistPaginationAndPartialDecoding() async throws {
        let httpClient = QueueHTTPClient([
            .json(
                """
                {
                  "href": "page-1",
                  "limit": 1,
                  "next": "https://api.spotify.com/v1/me/playlists?offset=1&limit=1",
                  "offset": 0,
                  "previous": null,
                  "total": 2,
                  "items": [
                    {
                      "id": "playlist-1",
                      "name": "One",
                      "description": "",
                      "owner": { "id": "owner-1", "display_name": null },
                      "images": [],
                      "items": { "total": 10 },
                      "public": null,
                      "collaborative": false,
                      "snapshot_id": "snapshot-1"
                    }
                  ]
                }
                """),
            .json(
                """
                {
                  "href": "page-2",
                  "limit": 1,
                  "next": null,
                  "offset": 1,
                  "previous": "https://api.spotify.com/v1/me/playlists?offset=0&limit=1",
                  "total": 2,
                  "items": [
                    {
                      "id": "playlist-2",
                      "name": "Two",
                      "description": "Second playlist",
                      "owner": { "id": "owner-2", "display_name": "Owner Two" },
                      "images": [{ "url": "https://example.com/300.png", "height": 300, "width": 300 }],
                      "items": { "total": 5 },
                      "public": true,
                      "collaborative": true,
                      "snapshot_id": "snapshot-2"
                    }
                  ]
                }
                """),
        ])
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let playlists = try await client.currentUserPlaylists(limit: 1)

        XCTAssertEqual(playlists.map(\.id), ["playlist-1", "playlist-2"])
        XCTAssertEqual(playlists.map(\.trackCount), [10, 5])
        XCTAssertEqual(playlists[0].ownerName, "owner-1")
        XCTAssertEqual(playlists[1].ownerName, "Owner Two")
        XCTAssertEqual(httpClient.requests.count, 2)
        XCTAssertEqual(
            httpClient.requests[0].url?.absoluteString, "https://api.spotify.com/v1/me/playlists?limit=1&offset=0")
        XCTAssertEqual(
            httpClient.requests[1].url?.absoluteString, "https://api.spotify.com/v1/me/playlists?offset=1&limit=1")
    }

    func testPlaylistPaginationStopsAtConfiguredPageCap() async throws {
        // Each page must advertise a distinct `next` URL; `collectPaged` stops if Spotify repeats the same `next`
        // link while pagination is still ongoing (defensive loop guard).
        let responses: [QueueHTTPClient.Response] = (0..<20).map { idx in
            let nextJSON: String
            if idx < 19 {
                nextJSON = "\"https://api.spotify.com/v1/me/playlists?offset=\(idx + 1)&limit=1\""
            } else {
                nextJSON = "null"
            }
            return .json(
                """
                {
                  "href": "page-\(idx)",
                  "limit": 1,
                  "next": \(nextJSON),
                  "offset": \(idx),
                  "previous": null,
                  "total": 100,
                  "items": [
                    {
                      "id": "playlist-\(idx)",
                      "name": "Page \(idx)",
                      "owner": { "id": "owner-1" },
                      "images": [],
                      "items": { "total": 1 },
                      "snapshot_id": "snapshot-\(idx)"
                    }
                  ]
                }
                """)
        }
        let httpClient = QueueHTTPClient(responses)
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let playlists = try await client.currentUserPlaylists(limit: 1)

        XCTAssertEqual(playlists.count, 20)
        XCTAssertEqual(playlists.map(\.id), (0..<20).map { "playlist-\($0)" })
        XCTAssertEqual(httpClient.requests.count, 20)
    }

    func testPlaylistPaginationBreaksWhenNextURLRepeats() async throws {
        let repeated = "https://api.spotify.com/v1/me/playlists?offset=1&limit=1"
        let httpClient = QueueHTTPClient([
            .json(
                """
                {
                  "href": "page-1",
                  "limit": 1,
                  "next": "\(repeated)",
                  "offset": 0,
                  "previous": null,
                  "total": 3,
                  "items": [
                    {
                      "id": "playlist-1",
                      "name": "One",
                      "owner": { "id": "owner-1" },
                      "images": [],
                      "items": { "total": 1 },
                      "snapshot_id": "snapshot-1"
                    }
                  ]
                }
                """),
            .json(
                """
                {
                  "href": "page-2",
                  "limit": 1,
                  "next": "\(repeated)",
                  "offset": 1,
                  "previous": null,
                  "total": 3,
                  "items": [
                    {
                      "id": "playlist-2",
                      "name": "Two",
                      "owner": { "id": "owner-2" },
                      "images": [],
                      "items": { "total": 1 },
                      "snapshot_id": "snapshot-2"
                    }
                  ]
                }
                """),
        ])
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let playlists = try await client.currentUserPlaylists(limit: 1)

        XCTAssertEqual(playlists.map(\.id), ["playlist-1", "playlist-2"])
        XCTAssertEqual(httpClient.requests.count, 2)
    }
}
