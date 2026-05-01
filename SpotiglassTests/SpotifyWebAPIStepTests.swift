import XCTest
@testable import Spotiglass

final class SpotifyWebAPIStepTests: XCTestCase {
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
        XCTAssertEqual(profile.imageURL?.absoluteString, "https://example.com/64.png")
        XCTAssertEqual(profile.country, "NL")
        XCTAssertEqual(profile.product, .unknown)
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
        XCTAssertNil(profile.imageURL)
        XCTAssertNil(profile.country)
        XCTAssertEqual(profile.product, .unknown)
    }

    func testPlaylistPaginationAndPartialDecoding() async throws {
        let httpClient = QueueHTTPClient([
            .json("""
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
            .json("""
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
            """)
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let playlists = try await client.currentUserPlaylists(limit: 1)

        XCTAssertEqual(playlists.map(\.id), ["playlist-1", "playlist-2"])
        XCTAssertEqual(playlists.map(\.trackCount), [10, 5])
        XCTAssertNil(playlists[0].description)
        XCTAssertEqual(playlists[0].ownerName, "owner-1")
        XCTAssertEqual(playlists[1].ownerName, "Owner Two")
        XCTAssertEqual(httpClient.requests.count, 2)
        XCTAssertEqual(httpClient.requests[0].url?.absoluteString, "https://api.spotify.com/v1/me/playlists?limit=1&offset=0")
        XCTAssertEqual(httpClient.requests[1].url?.absoluteString, "https://api.spotify.com/v1/me/playlists?offset=1&limit=1")
    }

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
        XCTAssertFalse(playlists[0].isCollaborative)
        XCTAssertEqual(playlists[0].snapshotID, "playlist-1")
    }

    func testPlaylistTrackDecodingHandlesTrackEpisodeLocalUnavailableAndNull() async throws {
        let httpClient = QueueHTTPClient([
            .json("""
            {
              "href": "items",
              "limit": 50,
              "next": null,
              "offset": 0,
              "previous": null,
              "total": 5,
              "items": [
                {
                  "added_at": "2026-04-28T07:00:00Z",
                  "is_local": false,
                  "item": {
                    "type": "track",
                    "id": "track-1",
                    "name": "Track One",
                    "artists": [{ "name": "Artist One" }],
                    "album": { "name": "Album", "images": [{ "url": "https://example.com/art.png", "height": 640, "width": 640 }] },
                    "duration_ms": 180000,
                    "explicit": true,
                    "is_playable": false,
                    "linked_from": { "id": "original-track" },
                    "uri": "spotify:track:track-1",
                    "is_local": false
                  }
                },
                {
                  "added_at": null,
                  "is_local": false,
                  "item": {
                    "type": "episode",
                    "id": "episode-1",
                    "name": "Episode One",
                    "show": { "name": "Show One" },
                    "images": [],
                    "duration_ms": 1200000,
                    "explicit": false,
                    "is_playable": true,
                    "uri": "spotify:episode:episode-1"
                  }
                },
                {
                  "added_at": null,
                  "is_local": true,
                  "item": {
                    "type": "track",
                    "id": null,
                    "name": "Local Song",
                    "artists": [{ "name": "Local Artist" }],
                    "album": { "name": "Local Album", "images": [] },
                    "duration_ms": 200000,
                    "explicit": false,
                    "is_playable": null,
                    "linked_from": null,
                    "uri": "spotify:local:local-song",
                    "is_local": true
                  }
                },
                {
                  "added_at": null,
                  "is_local": false,
                  "item": {
                    "type": "track",
                    "id": null,
                    "name": "Unavailable",
                    "artists": [],
                    "album": { "name": null, "images": [] },
                    "duration_ms": 0,
                    "explicit": false,
                    "is_playable": false,
                    "linked_from": null,
                    "uri": "spotify:track:unavailable",
                    "is_local": false
                  }
                },
                {
                  "added_at": null,
                  "is_local": false,
                  "item": null
                }
              ]
            }
            """)
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let tracks = try await client.playlistTracks(playlistID: "playlist-1")

        XCTAssertEqual(tracks.count, 5)
        guard case let .track(track) = tracks[0].content else {
            return XCTFail("Expected track")
        }
        XCTAssertEqual(track.id, "track-1")
        XCTAssertEqual(track.artists, ["Artist One"])
        XCTAssertEqual(track.linkedFromID, "original-track")

        guard case let .episode(episode) = tracks[1].content else {
            return XCTFail("Expected episode")
        }
        XCTAssertEqual(episode.showName, "Show One")

        guard case let .localTrack(localTrack) = tracks[2].content else {
            return XCTFail("Expected local track")
        }
        XCTAssertEqual(localTrack.albumName, "Local Album")

        guard case .unavailable = tracks[3].content else {
            return XCTFail("Expected unavailable track")
        }
        guard case .unavailable = tracks[4].content else {
            return XCTFail("Expected unavailable null item")
        }

        XCTAssertEqual(httpClient.requests.first?.url?.absoluteString, "https://api.spotify.com/v1/playlists/playlist-1/items?limit=50&offset=0")
    }

    func testPlaylistTrackDecodingPrefersItemAndFallsBackToLegacyTrackField() async throws {
        let httpClient = QueueHTTPClient([
            .json("""
            {
              "href": "items",
              "limit": 50,
              "next": null,
              "offset": 0,
              "previous": null,
              "total": 2,
              "items": [
                {
                  "added_at": null,
                  "is_local": false,
                  "item": {
                    "type": "track",
                    "id": "primary-track",
                    "name": "Primary",
                    "artists": [{ "name": "Primary Artist" }],
                    "album": { "name": "Primary Album", "images": [] },
                    "duration_ms": 1000,
                    "explicit": false,
                    "uri": "spotify:track:primary-track",
                    "is_local": false
                  },
                  "track": {
                    "type": "track",
                    "id": "shadow-track",
                    "name": "Should Be Ignored",
                    "artists": [],
                    "album": { "name": null, "images": [] },
                    "duration_ms": 0,
                    "explicit": false,
                    "uri": "spotify:track:shadow-track",
                    "is_local": false
                  }
                },
                {
                  "added_at": null,
                  "is_local": false,
                  "track": {
                    "type": "track",
                    "id": "legacy-track",
                    "name": "Legacy",
                    "artists": [{ "name": "Legacy Artist" }],
                    "album": { "name": "Legacy Album", "images": [] },
                    "duration_ms": 2000,
                    "explicit": false,
                    "uri": "spotify:track:legacy-track",
                    "is_local": false
                  }
                }
              ]
            }
            """)
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let tracks = try await client.playlistTracks(playlistID: "playlist-1")

        XCTAssertEqual(tracks.count, 2)
        guard case let .track(primary) = tracks[0].content else {
            return XCTFail("Expected primary track from `item` field")
        }
        XCTAssertEqual(primary.id, "primary-track")
        XCTAssertEqual(primary.name, "Primary")

        guard case let .track(legacy) = tracks[1].content else {
            return XCTFail("Expected legacy track from fallback `track` field")
        }
        XCTAssertEqual(legacy.id, "legacy-track")
        XCTAssertEqual(legacy.name, "Legacy")
    }

    func testPlaylistTrackDecodingToleratesMissingSpotifyOptionalFields() async throws {
        let httpClient = QueueHTTPClient([
            .json("""
            {
              "limit": 50,
              "offset": 0,
              "total": 3,
              "items": [
                {
                  "item": {
                    "type": "track",
                    "id": "track-1",
                    "name": "Sparse Track"
                  }
                },
                {
                  "item": {
                    "type": "episode",
                    "id": "episode-1"
                  }
                },
                {
                  "item": {
                    "type": "track",
                    "name": "Unavailable Missing ID"
                  }
                }
              ]
            }
            """)
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let tracks = try await client.playlistTracks(playlistID: "playlist-1")

        XCTAssertEqual(tracks.count, 3)
        guard case let .track(track) = tracks[0].content else {
            return XCTFail("Expected sparse track")
        }
        XCTAssertEqual(track.name, "Sparse Track")
        XCTAssertEqual(track.artists, [])
        XCTAssertEqual(track.durationMilliseconds, 0)
        XCTAssertEqual(track.uri, "spotify:track:track-1")

        guard case let .episode(episode) = tracks[1].content else {
            return XCTFail("Expected sparse episode")
        }
        XCTAssertEqual(episode.name, "Unknown episode")
        XCTAssertEqual(episode.showName, nil)
        XCTAssertEqual(episode.uri, "spotify:episode:episode-1")

        guard case .unavailable = tracks[2].content else {
            return XCTFail("Expected unavailable item for missing track ID")
        }
    }

    func testSearchDecodingMapsTracksArtistsAlbumsAndPlaylists() async throws {
        let httpClient = QueueHTTPClient([
            .json("""
            {
              "tracks": {
                "items": [
                  {
                    "type": "track",
                    "id": "track-1",
                    "name": "Midnight City",
                    "artists": [{ "name": "M83" }],
                    "album": { "images": [] },
                    "duration_ms": 240000,
                    "explicit": false,
                    "uri": "spotify:track:track-1"
                  }
                ]
              },
              "artists": {
                "items": [
                  { "id": "artist-1", "name": "M83", "images": [], "uri": "spotify:artist:artist-1" }
                ]
              },
              "albums": {
                "items": [
                  {
                    "id": "album-1",
                    "name": "Hurry Up, We're Dreaming",
                    "artists": [{ "name": "M83" }],
                    "images": [],
                    "uri": "spotify:album:album-1"
                  }
                ]
              },
              "playlists": {
                "items": [
                  {
                    "id": "playlist-1",
                    "name": "Midnight",
                    "owner": { "id": "owner-1", "display_name": "Isaac" },
                    "images": [],
                    "items": { "total": 10 },
                    "snapshot_id": "snapshot-1"
                  }
                ]
              }
            }
            """)
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let results = try await client.search(query: "Midnight", limit: 4)

        XCTAssertEqual(results.tracks.map(\.id), ["track-1"])
        XCTAssertEqual(results.artists.map(\.name), ["M83"])
        XCTAssertEqual(results.albums.map(\.id), ["album-1"])
        XCTAssertEqual(results.playlists.map(\.id), ["playlist-1"])
        XCTAssertEqual(
            httpClient.requests.first?.url?.absoluteString,
            "https://api.spotify.com/v1/search?q=Midnight&type=track,artist,album,playlist&limit=4"
        )
    }

    func testErrorMappingCoversRateLimitForbiddenAuthDecodeAndNetwork() async throws {
        let rateLimited = QueueHTTPClient([
            .json("""
            { "error": { "status": 429, "message": "Slow down" } }
            """, statusCode: 429, headers: ["Retry-After": "7"])
        ])
        let rateLimitedClient = SpotifyAPIClient(tokenProvider: FailingRefreshTokenProvider(), httpClient: rateLimited)
        await XCTAssertThrowsSpotifyAPIError(try await rateLimitedClient.currentUserProfile(), .rateLimited(retryAfter: 7))

        let forbidden = QueueHTTPClient([
            .json("""
            { "error": { "status": 403, "message": "Forbidden" } }
            """, statusCode: 403)
        ])
        let forbiddenClient = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: forbidden)
        do {
            _ = try await forbiddenClient.currentUserProfile()
            XCTFail("Expected forbidden")
        } catch let error as SpotifyAPIError {
            guard case let .forbidden(message, details) = error else {
                return XCTFail("Expected forbidden, got \(error)")
            }
            XCTAssertEqual(message, "Forbidden")
            XCTAssertTrue(details?.contains("GET https://api.spotify.com/v1/me") == true)
            XCTAssertTrue(details?.contains("HTTP 403") == true)
            XCTAssertTrue(details?.contains("Response body:") == true)
            XCTAssertTrue(details?.contains("\"message\": \"Forbidden\"") == true)
        }

        let insufficientScope = QueueHTTPClient([
            .json("""
            { "error": { "status": 403, "message": "Insufficient client scope" } }
            """, statusCode: 403, headers: ["WWW-Authenticate": "Bearer realm=\"spotify\", error=\"insufficient_scope\", scope=\"playlist-read-private playlist-read-collaborative\""])
        ])
        let insufficientScopeClient = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: insufficientScope)
        do {
            _ = try await insufficientScopeClient.playlistTracks(playlistID: "playlist-1")
            XCTFail("Expected insufficient scope")
        } catch let error as SpotifyAPIError {
            guard case let .insufficientScope(requiredScopes, message, details) = error else {
                return XCTFail("Expected insufficient scope, got \(error)")
            }
            XCTAssertEqual(requiredScopes, ["playlist-read-private", "playlist-read-collaborative"])
            XCTAssertEqual(message, "Insufficient client scope")
            XCTAssertTrue(details?.contains("GET https://api.spotify.com/v1/playlists/playlist-1/items?limit=50&offset=0") == true)
            XCTAssertTrue(details?.contains("HTTP 403") == true)
            XCTAssertTrue(details?.contains("insufficient_scope") == true)
        }

        let genericForbiddenPlaylistTracks = QueueHTTPClient([
            .json("""
            { "error": { "status": 403, "message": "Forbidden" } }
            """, statusCode: 403)
        ])
        let genericForbiddenPlaylistTracksClient = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: genericForbiddenPlaylistTracks)
        do {
            _ = try await genericForbiddenPlaylistTracksClient.playlistTracks(playlistID: "playlist-1")
            XCTFail("Expected forbidden")
        } catch let error as SpotifyAPIError {
            guard case let .forbidden(message, details) = error else {
                return XCTFail("Expected forbidden, got \(error)")
            }
            XCTAssertEqual(message, "Forbidden")
            XCTAssertTrue(details?.contains("GET https://api.spotify.com/v1/playlists/playlist-1/items?limit=50&offset=0") == true)
            XCTAssertTrue(details?.contains("HTTP 403") == true)
            XCTAssertTrue(details?.contains("\"message\": \"Forbidden\"") == true)
        }

        let unauthorized = QueueHTTPClient([
            .json("""
            { "error": { "status": 401, "message": "Expired" } }
            """, statusCode: 401),
            .json("""
            { "error": { "status": 401, "message": "Still expired" } }
            """, statusCode: 401)
        ])
        let unauthorizedClient = SpotifyAPIClient(tokenProvider: RefreshingTokenProvider(), httpClient: unauthorized)
        await XCTAssertThrowsSpotifyAPIError(try await unauthorizedClient.currentUserProfile(), .unauthorized)

        let badJSON = QueueHTTPClient([.data(Data("{".utf8), statusCode: 200)])
        let badJSONClient = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: badJSON)
        do {
            _ = try await badJSONClient.currentUserProfile()
            XCTFail("Expected decode error")
        } catch let error as SpotifyAPIError {
            guard case .decoding = error else {
                return XCTFail("Expected decode error, got \(error)")
            }
        }

        let networkClient = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"),
            httpClient: ThrowingHTTPClient()
        )
        do {
            _ = try await networkClient.currentUserProfile()
            XCTFail("Expected network error")
        } catch let error as SpotifyAPIError {
            guard case .network = error else {
                return XCTFail("Expected network error, got \(error)")
            }
        }
    }

    func testUnauthorizedRefreshRetriesWithFreshToken() async throws {
        let httpClient = QueueHTTPClient([
            .json("""
            { "error": { "status": 401, "message": "Expired" } }
            """, statusCode: 401),
            .json("""
            {
              "id": "user-1",
              "display_name": "Refreshed",
              "images": [],
              "country": null,
              "product": "premium"
            }
            """)
        ])
        let tokenProvider = RefreshingTokenProvider()
        let client = SpotifyAPIClient(tokenProvider: tokenProvider, httpClient: httpClient)

        let profile = try await client.currentUserProfile()

        XCTAssertEqual(profile.displayName, "Refreshed")
        XCTAssertEqual(httpClient.requests.map { $0.value(forHTTPHeaderField: "Authorization") }, [
            "Bearer stale-token",
            "Bearer fresh-token"
        ])
        XCTAssertEqual(tokenProvider.refreshCount, 1)
    }

    func testCachePersistsAndInvalidatesByAgeAndSnapshot() throws {
        let cache = try SpotifyLocalCache(rootDirectory: temporaryDirectory())
        let playlist = SpotifyPlaylistSummary(
            id: "playlist-1",
            name: "Playlist",
            description: nil,
            ownerName: "Owner",
            imageURL: nil,
            trackCount: 1,
            isPublic: nil,
            isCollaborative: false,
            snapshotID: "snapshot-1"
        )
        let track = SpotifyPlaylistTrackItem(
            id: "track-1",
            addedAt: nil,
            content: .track(SpotifyTrack(
                id: "track-1",
                name: "Track",
                artists: ["Artist"],
                albumArtworkURL: nil,
                durationMilliseconds: 100,
                isExplicit: false,
                isPlayable: true,
                linkedFromID: nil,
                uri: "spotify:track:track-1"
            ))
        )
        let cachedAt = Date(timeIntervalSince1970: 1_000)

        try cache.savePlaylists([playlist], cachedAt: cachedAt)
        try cache.saveTracks([track], playlistID: "playlist-1", snapshotID: "snapshot-1", cachedAt: cachedAt)
        try cache.saveSettings(CachedSpotifySettings(lastSelectedPlaylistID: "playlist-1", lastUserID: "user-1"))

        XCTAssertEqual(try cache.loadPlaylists(now: Date(timeIntervalSince1970: 1_100), maxAge: 300), [playlist])
        XCTAssertNil(try cache.loadPlaylists(now: Date(timeIntervalSince1970: 1_400), maxAge: 300))
        XCTAssertEqual(try cache.loadTracks(playlistID: "playlist-1", snapshotID: "snapshot-1", now: Date(timeIntervalSince1970: 1_100), maxAge: 300), [track])
        XCTAssertNil(try cache.loadTracks(playlistID: "playlist-1", snapshotID: "snapshot-2", now: Date(timeIntervalSince1970: 1_100), maxAge: 300))
        XCTAssertEqual(try cache.loadSettings(), CachedSpotifySettings(lastSelectedPlaylistID: "playlist-1", lastUserID: "user-1"))

        try cache.invalidateTracks(playlistID: "playlist-1")
        XCTAssertNil(try cache.loadTracks(playlistID: "playlist-1", snapshotID: "snapshot-1", now: Date(timeIntervalSince1970: 1_100), maxAge: 300))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SpotiglassTests-\(UUID().uuidString)", isDirectory: true)
    }
}

private func XCTAssertThrowsSpotifyAPIError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ expectedError: SpotifyAPIError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected \(expectedError)", file: file, line: line)
    } catch let error as SpotifyAPIError {
        XCTAssertEqual(error, expectedError, file: file, line: line)
    } catch {
        XCTFail("Expected SpotifyAPIError, got \(error)", file: file, line: line)
    }
}

private final class QueueHTTPClient: HTTPClient {
    struct Response {
        let data: Data
        let statusCode: Int
        let headers: [String: String]

        static func json(_ string: String, statusCode: Int = 200, headers: [String: String] = [:]) -> Response {
            Response(data: Data(string.utf8), statusCode: statusCode, headers: headers)
        }

        static func data(_ data: Data, statusCode: Int = 200, headers: [String: String] = [:]) -> Response {
            Response(data: data, statusCode: statusCode, headers: headers)
        }
    }

    private var responses: [Response]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw URLError(.badServerResponse)
        }
        let response = responses.removeFirst()
        return (
            response.data,
            HTTPURLResponse(
                url: request.url!,
                statusCode: response.statusCode,
                httpVersion: nil,
                headerFields: response.headers
            )!
        )
    }
}

private final class ThrowingHTTPClient: HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

private final class RefreshingTokenProvider: SpotifyAccessTokenProviding {
    private(set) var refreshCount = 0

    func accessToken() async throws -> String {
        "stale-token"
    }

    func refreshAccessTokenAfterUnauthorized() async throws -> String {
        refreshCount += 1
        return "fresh-token"
    }
}

private struct FailingRefreshTokenProvider: SpotifyAccessTokenProviding {
    func accessToken() async throws -> String {
        "token"
    }

    func refreshAccessTokenAfterUnauthorized() async throws -> String {
        throw SpotifyAPIError.unauthorized
    }
}
