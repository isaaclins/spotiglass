import XCTest

@testable import Spotiglass

final class SpotifyAPIClientSavedTracksPaginationTests: XCTestCase {
    func testCurrentUserSavedTracksDecodesMeTracksPage() async throws {
        let httpClient = QueueHTTPClient([
            .json(
                """
                {
                  "href": "https://api.spotify.com/v1/me/tracks",
                  "limit": 50,
                  "offset": 0,
                  "next": null,
                  "previous": null,
                  "total": 1,
                  "items": [
                    {
                      "added_at": "2020-01-01T00:00:00Z",
                      "track": {
                        "type": "track",
                        "id": "saved-1",
                        "name": "Liked Name",
                        "artists": [{ "id": "artist-1", "name": "Artist" }],
                        "album": { "name": "Album", "images": [] },
                        "duration_ms": 180000,
                        "explicit": false,
                        "uri": "spotify:track:saved-1",
                        "is_local": false
                      }
                    }
                  ]
                }
                """)
        ])
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let result = try await client.currentUserSavedTracks(limit: 50, maxPages: 20)

        XCTAssertEqual(result.totalAvailable, 1)
        XCTAssertEqual(result.tracks.count, 1)
        guard case .track(let track) = result.tracks[0].content else {
            return XCTFail("Expected track")
        }
        XCTAssertEqual(track.id, "saved-1")
        XCTAssertEqual(track.name, "Liked Name")
        XCTAssertEqual(
            httpClient.requests.first?.url?.absoluteString, "https://api.spotify.com/v1/me/tracks?limit=50&offset=0")
    }

    func testCurrentUserSavedTracksStopsWhenNextOffsetRepeats() async throws {
        let loopingPage = """
            {
              "href": "https://api.spotify.com/v1/me/tracks?limit=50&offset=0",
              "limit": 50,
              "offset": 0,
              "next": "https://api.spotify.com/v1/me/tracks?limit=50&offset=0",
              "previous": null,
              "total": 200,
              "items": [
                {
                  "added_at": "2020-01-01T00:00:00Z",
                  "track": {
                    "type": "track",
                    "id": "saved-loop",
                    "name": "Loop",
                    "artists": [{ "id": "artist-1", "name": "Artist" }],
                    "album": { "name": "Album", "images": [] },
                    "duration_ms": 180000,
                    "explicit": false,
                    "uri": "spotify:track:saved-loop",
                    "is_local": false
                  }
                }
              ]
            }
            """
        let httpClient = QueueHTTPClient([
            .json(loopingPage),
            .json(loopingPage),
        ])
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let result = try await client.currentUserSavedTracks(limit: 50, maxPages: 20)

        XCTAssertEqual(result.tracks.count, 1)
        XCTAssertEqual(
            httpClient.requests.count, 1, "A repeated next offset should break pagination before re-fetching page 1.")
    }
}
