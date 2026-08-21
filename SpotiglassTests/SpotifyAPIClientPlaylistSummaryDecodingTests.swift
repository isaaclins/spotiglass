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

    func testAddTracksToPlaylistUsesItemsRouteAndKeepsHundredURIRequestsBatched() async throws {
        let httpClient = QueueHTTPClient([
            .data(Data(), statusCode: 201),
            .data(Data(), statusCode: 201)
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)
        let uris = (0..<101).map { "spotify:track:track-\($0)" }

        try await client.addTracksToPlaylist(playlistID: "playlist-1", uris: uris)

        XCTAssertEqual(httpClient.requests.count, 2)
        XCTAssertEqual(httpClient.requests[0].httpMethod, "POST")
        XCTAssertEqual(httpClient.requests[0].url?.absoluteString, "https://api.spotify.com/v1/playlists/playlist-1/items")
        let firstBody = try XCTUnwrap(httpClient.requests[0].httpBody)
        let firstObject = try XCTUnwrap(JSONSerialization.jsonObject(with: firstBody) as? [String: [String]])
        XCTAssertEqual(firstObject["uris"], Array(uris.prefix(100)))
        let secondBody = try XCTUnwrap(httpClient.requests[1].httpBody)
        let secondObject = try XCTUnwrap(JSONSerialization.jsonObject(with: secondBody) as? [String: [String]])
        XCTAssertEqual(secondObject["uris"], Array(uris.suffix(1)))
    }

    func testRemoveTracksFromPlaylistUsesPositionsAndPreservesOrderInBatches() async throws {
        let httpClient = QueueHTTPClient([
            .data(Data(), statusCode: 200),
            .data(Data(), statusCode: 200)
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)
        let removals = (0..<101).map {
            SpotifyPlaylistTrackRemoval(uri: "spotify:track:track-\($0)", positions: [$0])
        }

        try await client.removeTracksFromPlaylist(
            playlistID: "playlist-1",
            items: removals,
            snapshotID: nil
        )

        XCTAssertEqual(httpClient.requests.count, 2)
        XCTAssertEqual(httpClient.requests[0].httpMethod, "DELETE")
        XCTAssertEqual(httpClient.requests[0].url?.absoluteString, "https://api.spotify.com/v1/playlists/playlist-1/items")
        let firstBody = try XCTUnwrap(httpClient.requests[0].httpBody)
        let firstObject = try XCTUnwrap(JSONSerialization.jsonObject(with: firstBody) as? [String: Any])
        let firstItems = try XCTUnwrap(firstObject["items"] as? [[String: Any]])
        // Batches run from the end of the playlist backwards so that deleting
        // one batch cannot shift the positions still queued in the next one.
        XCTAssertEqual(
            firstItems.compactMap { $0["uri"] as? String },
            (1...100).reversed().map { "spotify:track:track-\($0)" }
        )
        XCTAssertEqual(
            firstItems.compactMap { $0["positions"] as? [Int] },
            (1...100).reversed().map { [$0] }
        )
        let secondBody = try XCTUnwrap(httpClient.requests[1].httpBody)
        let secondObject = try XCTUnwrap(JSONSerialization.jsonObject(with: secondBody) as? [String: Any])
        let secondItems = try XCTUnwrap(secondObject["items"] as? [[String: Any]])
        XCTAssertEqual(secondItems.compactMap { $0["uri"] as? String }, ["spotify:track:track-0"])
        XCTAssertEqual(secondItems.compactMap { $0["positions"] as? [Int] }, [[0]])
    }

    func testAddTracksToPlaylistPreservesDuplicateOccurrences() async throws {
        let httpClient = QueueHTTPClient([
            .data(Data(), statusCode: 201)
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        try await client.addTracksToPlaylist(
            playlistID: "playlist-1",
            uris: ["spotify:track:duplicate", "spotify:track:duplicate"]
        )

        let request = try XCTUnwrap(httpClient.requests.first)
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: [String]])
        XCTAssertEqual(object["uris"], ["spotify:track:duplicate", "spotify:track:duplicate"])
    }

    func testRemoveTracksFromPlaylistUsesPositionsAndSnapshotID() async throws {
        let httpClient = QueueHTTPClient([
            .data(Data(), statusCode: 200)
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)
        let removals = [
            SpotifyPlaylistTrackRemoval(uri: "spotify:track:duplicate", positions: [0, 2]),
            SpotifyPlaylistTrackRemoval(uri: "spotify:track:other", positions: [4])
        ]

        try await client.removeTracksFromPlaylist(
            playlistID: "playlist-1",
            items: removals,
            snapshotID: "snapshot-1"
        )

        let request = try XCTUnwrap(httpClient.requests.first)
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let items = try XCTUnwrap(object["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)
        // Highest position first, and the duplicate's two slots merge into one
        // entry because a single request is applied against a single snapshot.
        XCTAssertEqual(items[0]["uri"] as? String, "spotify:track:other")
        XCTAssertEqual(items[0]["positions"] as? [Int], [4])
        XCTAssertEqual(items[1]["uri"] as? String, "spotify:track:duplicate")
        XCTAssertEqual(items[1]["positions"] as? [Int], [2, 0])
        XCTAssertEqual(object["snapshot_id"] as? String, "snapshot-1")
    }

    func testCreatePlaylistUsesCurrentUserRouteAndPreservesBody() async throws {
        let httpClient = QueueHTTPClient([
            .json("""
            {
              "id": "playlist-1",
              "name": "New Playlist",
              "owner": { "id": "user-1", "display_name": "User" },
              "images": [],
              "items": { "total": 0 },
              "snapshot_id": "snapshot-1"
            }
            """, statusCode: 201)
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let created = try await client.createPlaylist(userID: "user-1", name: "  New Playlist  ", isPublic: true)

        let request = try XCTUnwrap(httpClient.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.spotify.com/v1/me/playlists")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["name"] as? String, "New Playlist")
        XCTAssertEqual(object["public"] as? Bool, true)
        XCTAssertEqual(created.id, "playlist-1")
    }

    func testUpdatePlaylistSendsPUTRequestWithNameOnly() async throws {
        let httpClient = QueueHTTPClient([
            .data(Data(), statusCode: 204)
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        try await client.updatePlaylist(playlistID: "playlist-1", name: "  Renamed Playlist  ")

        let request = try XCTUnwrap(httpClient.requests.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.absoluteString, "https://api.spotify.com/v1/playlists/playlist-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(object, ["name": "Renamed Playlist"])
    }

    func testUpdatePlaylistRejectsWhitespaceOnlyName() async throws {
        let httpClient = QueueHTTPClient([])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        await XCTAssertThrowsSpotifyAPIError(
            try await client.updatePlaylist(playlistID: "playlist-1", name: " \n\t "),
            .invalidRequest("Playlist name is required.")
        )
        XCTAssertTrue(httpClient.requests.isEmpty)
    }

    func testOmittedPlaylistItemsStayUnavailableThroughCacheAndSidebarRows() async throws {
        let httpClient = QueueHTTPClient([
            .json("""
            {
              "limit": 2,
              "offset": 0,
              "total": 2,
              "next": null,
              "items": [
                {
                  "id": "followed-playlist",
                  "name": "Followed",
                  "owner": { "id": "owner-1", "display_name": "Owner" },
                  "images": [],
                  "snapshot_id": "snapshot-followed"
                },
                {
                  "id": "empty-playlist",
                  "name": "Empty",
                  "owner": { "id": "owner-2", "display_name": "Owner Two" },
                  "images": [],
                  "items": { "total": 0 },
                  "snapshot_id": "snapshot-empty"
                }
              ]
            }
            """),
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)
        let playlists = try await client.currentUserPlaylists(limit: 2)
        let cache = try SpotifyLocalCache(rootDirectory: spotiglassTestsTemporaryDirectory())

        try cache.savePlaylists(playlists, cachedAt: Date(timeIntervalSince1970: 1_000))
        let cachedPlaylists = try XCTUnwrap(cache.loadPlaylistsBundle(now: Date(timeIntervalSince1970: 1_001))).playlists
        let rows = cachedPlaylists.map(PlaylistRowViewModel.init)

        XCTAssertEqual(rows.map(\.trackCountText), [
            "Track count unavailable",
            SpotiglassL10n.format("browser.trackCount", Int64(0)),
        ])
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
