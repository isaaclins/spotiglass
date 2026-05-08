import XCTest
@testable import Spotiglass

final class SpotifyAPIClientPlaylistSummaryDecodingTests: XCTestCase {
    func testPlaylistDecodingFallsBackToLegacyTracksField() async throws {
        let httpClient = QueueHTTPClient([
            .json("""
            {
              "limit": 50,
              "offset": 0,
              "total": 1,
              "items": [
                {
                  "id": "legacy-playlist",
                  "name": "Legacy",
                  "owner": { "id": "owner-1" },
                  "images": [],
                  "tracks": { "total": 7 },
                  "snapshot_id": "snapshot-legacy"
                }
              ]
            }
            """)
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let playlists = try await client.currentUserPlaylists()

        XCTAssertEqual(playlists.map(\.id), ["legacy-playlist"])
        XCTAssertEqual(playlists.map(\.trackCount), [7])
    }

    func testPlaylistDecodingToleratesMissingSpotifyOptionalFields() async throws {
        let httpClient = QueueHTTPClient([
            .json("""
            {
              "limit": 50,
              "offset": 0,
              "total": 1,
              "items": [
                {
                  "id": "playlist-1",
                  "name": "Sparse Playlist",
                  "owner": {},
                  "images": [{ "height": 640, "width": 640 }],
                  "items": {}
                }
              ]
            }
            """)
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let playlists = try await client.currentUserPlaylists()

        XCTAssertEqual(playlists.count, 1)
        XCTAssertEqual(playlists[0].id, "playlist-1")
        XCTAssertEqual(playlists[0].name, "Sparse Playlist")
        XCTAssertEqual(playlists[0].ownerName, "unknown-owner")
        XCTAssertNil(playlists[0].imageURL)
        XCTAssertEqual(playlists[0].trackCount, 0)
        XCTAssertEqual(playlists[0].snapshotID, "playlist-1")
    }
}
