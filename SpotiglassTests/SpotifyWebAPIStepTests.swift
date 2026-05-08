import XCTest
@testable import Spotiglass

final class SpotifyWebAPIStepTests: XCTestCase {
    func testSearchClampsRequestedLimitToSpotifyMaximum() async throws {
        let httpClient = QueueHTTPClient([
            .json("""
            {
              "tracks": { "items": [] },
              "artists": { "items": [] },
              "albums": { "items": [] },
              "playlists": { "items": [] }
            }
            """)
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

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

    func testPlaylistPaginationStopsAtConfiguredPageCap() async throws {
        // Each page must advertise a distinct `next` URL; `collectPaged` stops if Spotify repeats the same `next`
        // link while pagination is still ongoing (defensive loop guard).
        let responses: [QueueHTTPClient.Response] = (0 ..< 20).map { idx in
            let nextJSON: String
            if idx < 19 {
                nextJSON = "\"https://api.spotify.com/v1/me/playlists?offset=\(idx + 1)&limit=1\""
            } else {
                nextJSON = "null"
            }
            return .json("""
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
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let playlists = try await client.currentUserPlaylists(limit: 1)

        XCTAssertEqual(playlists.count, 20)
        XCTAssertEqual(playlists.map(\.id), (0 ..< 20).map { "playlist-\($0)" })
        XCTAssertEqual(httpClient.requests.count, 20)
    }

    func testPlaylistPaginationBreaksWhenNextURLRepeats() async throws {
        let repeated = "https://api.spotify.com/v1/me/playlists?offset=1&limit=1"
        let httpClient = QueueHTTPClient([
            .json("""
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
            .json("""
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
            """)
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let playlists = try await client.currentUserPlaylists(limit: 1)

        XCTAssertEqual(playlists.map(\.id), ["playlist-1", "playlist-2"])
        XCTAssertEqual(httpClient.requests.count, 2)
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

    func testPlaylistTracksStopsAfterMaxPagesWhenNextIsNonNil() async throws {
        let itemJSON = """
        {
          "added_at": null,
          "is_local": false,
          "item": {
            "type": "track",
            "id": "page-track",
            "name": "Page Track",
            "artists": [{ "name": "A" }],
            "album": { "name": "Alb", "images": [] },
            "duration_ms": 1000,
            "explicit": false,
            "is_playable": true,
            "uri": "spotify:track:page-track",
            "is_local": false
          }
        }
        """
        func pageJSON(next: String?) -> String {
            let nextField = next.map { "\"\($0)\"" } ?? "null"
            return """
            {
              "href": "https://api.spotify.com/v1/playlists/p1/items",
              "limit": 1,
              "offset": 0,
              "next": \(nextField),
              "previous": null,
              "total": 99,
              "items": [\(itemJSON)]
            }
            """
        }
        let next1 = "https://api.spotify.com/v1/playlists/p1/items?offset=1&limit=1"
        let next2 = "https://api.spotify.com/v1/playlists/p1/items?offset=2&limit=1"
        let httpClient = QueueHTTPClient([
            .json(pageJSON(next: next1)),
            .json(pageJSON(next: next2))
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let tracks = try await client.playlistTracks(playlistID: "p1", limit: 1, maxPages: 2)

        XCTAssertEqual(httpClient.requests.count, 2)
        XCTAssertEqual(tracks.count, 2)
    }

    func testPlaylistTracksCancellationSkipsSecondPageRequest() async throws {
        let itemJSON = """
        {
          "added_at": null,
          "is_local": false,
          "item": {
            "type": "track",
            "id": "t-page-1",
            "name": "One",
            "artists": [{ "name": "A" }],
            "album": { "name": "Alb", "images": [] },
            "duration_ms": 1000,
            "explicit": false,
            "is_playable": true,
            "uri": "spotify:track:t-page-1",
            "is_local": false
          }
        }
        """
        let page1 = """
        {
          "href": "https://api.spotify.com/v1/playlists/p1/items",
          "limit": 1,
          "offset": 0,
          "next": "https://api.spotify.com/v1/playlists/p1/items?offset=1&limit=1",
          "previous": null,
          "total": 2,
          "items": [\(itemJSON)]
        }
        """
        let page2 = """
        {
          "href": "https://api.spotify.com/v1/playlists/p1/items",
          "limit": 1,
          "offset": 1,
          "next": null,
          "previous": null,
          "total": 2,
          "items": [\(itemJSON)]
        }
        """
        // Yield after the first page so this test task can cancel before `collectPaged` issues page 2
        // (otherwise both requests can complete synchronously before we observe `requests.count == 1`).
        let httpClient = YieldAfterFirstResponseHTTPClient([
            .json(page1),
            .json(page2)
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let task = Task {
            try await client.playlistTracks(playlistID: "p1", limit: 1, maxPages: 10)
        }
        for _ in 0..<500 {
            if httpClient.requests.count >= 1 { break }
            try await Task.sleep(nanoseconds: 100_000)
        }
        XCTAssertEqual(httpClient.requests.count, 1, "Expected exactly one request before cancellation")
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(httpClient.requests.count, 1)
    }

    func testCurrentUserSavedTracksDecodesMeTracksPage() async throws {
        let httpClient = QueueHTTPClient([
            .json("""
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
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let result = try await client.currentUserSavedTracks(limit: 50, maxPages: 20)

        XCTAssertEqual(result.totalAvailable, 1)
        XCTAssertEqual(result.tracks.count, 1)
        guard case let .track(track) = result.tracks[0].content else {
            return XCTFail("Expected track")
        }
        XCTAssertEqual(track.id, "saved-1")
        XCTAssertEqual(track.name, "Liked Name")
        XCTAssertEqual(httpClient.requests.first?.url?.absoluteString, "https://api.spotify.com/v1/me/tracks?limit=50&offset=0")
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
            .json(loopingPage)
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let result = try await client.currentUserSavedTracks(limit: 50, maxPages: 20)

        XCTAssertEqual(result.tracks.count, 1)
        XCTAssertEqual(httpClient.requests.count, 1, "A repeated next offset should break pagination before re-fetching page 1.")
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

    func testPlaylistTrackItemIDsAreUniqueWhenSameTrackAppearsTwice() async throws {
        let httpClient = QueueHTTPClient([
            .json("""
            {
              "limit": 50,
              "offset": 0,
              "total": 2,
              "items": [
                {
                  "is_local": false,
                  "item": {
                    "type": "track",
                    "id": "dup-track",
                    "name": "Same",
                    "artists": [{ "name": "A" }],
                    "album": { "name": "Alb", "images": [] },
                    "duration_ms": 1000,
                    "explicit": false,
                    "uri": "spotify:track:dup-track",
                    "is_local": false
                  }
                },
                {
                  "is_local": false,
                  "item": {
                    "type": "track",
                    "id": "dup-track",
                    "name": "Same",
                    "artists": [{ "name": "A" }],
                    "album": { "name": "Alb", "images": [] },
                    "duration_ms": 1000,
                    "explicit": false,
                    "uri": "spotify:track:dup-track",
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
        XCTAssertEqual(tracks[0].id, "dup-track:0")
        XCTAssertEqual(tracks[1].id, "dup-track:1")
        guard case let .track(a) = tracks[0].content, case let .track(b) = tracks[1].content else {
            return XCTFail("Expected two tracks")
        }
        XCTAssertEqual(a.id, "dup-track")
        XCTAssertEqual(b.id, "dup-track")
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

    func testSearchTracksUsesTypeTrackAndLimit() async throws {
        let httpClient = QueueHTTPClient([
            .json("""
            {
              "tracks": {
                "items": [
                  {
                    "type": "track",
                    "id": "track-99",
                    "name": "X",
                    "artists": [{ "name": "A" }],
                    "album": { "images": [] },
                    "duration_ms": 1000,
                    "explicit": false,
                    "uri": "spotify:track:track-99"
                  }
                ]
              }
            }
            """)
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        _ = try await client.searchTracks(query: "artist:\"Kanye West\"", limit: 50)

        XCTAssertEqual(
            httpClient.requests.first?.url?.absoluteString,
            "https://api.spotify.com/v1/search?q=artist:%22Kanye%20West%22&type=track&limit=10"
        )
    }

    func testSearchSecondCallUsesGETResponseCacheSingleHTTPRequest() async throws {
        let searchJSON = """
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
              "artists": { "items": [] },
              "albums": { "items": [] },
              "playlists": { "items": [] }
            }
            """
        let cache = SpotifyGETResponseCache(diskCache: nil)
        let httpClient = QueueHTTPClient([.json(searchJSON)])
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"),
            httpClient: httpClient,
            getResponseCache: cache
        )

        _ = try await client.search(query: "Midnight", limit: 4)
        let second = try await client.search(query: "Midnight", limit: 4)

        XCTAssertEqual(httpClient.requests.count, 1, "GET response cache should avoid a second HTTP request for the same search.")
        XCTAssertEqual(second.tracks.map(\.id), ["track-1"])
    }

    func testSearchCacheSharesKeyForCaseAndWhitespaceVariantsOfQ() async throws {
        let searchJSON = """
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
              "artists": { "items": [] },
              "albums": { "items": [] },
              "playlists": { "items": [] }
            }
            """
        let cache = SpotifyGETResponseCache(diskCache: nil)
        let httpClient = QueueHTTPClient([.json(searchJSON)])
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"),
            httpClient: httpClient,
            getResponseCache: cache
        )

        _ = try await client.search(query: "Midnight", limit: 4)
        _ = try await client.search(query: "  MIDNIGHT  ", limit: 4)

        XCTAssertEqual(httpClient.requests.count, 1, "Normalized cache keys should treat equivalent q parameters as one entry.")
    }

    func testRateLimitDisplayUsesFriendlyPhrasesForLongBackoffs() {
        XCTAssertTrue(SpotifyRateLimitDisplay.retryAfterClause(seconds: 7500).lowercased().contains("several hours"))
        XCTAssertTrue(SpotifyRateLimitDisplay.retryAfterClause(seconds: 400).lowercased().contains("minute"))
        XCTAssertEqual(SpotifyRateLimitDisplay.retryAfterClause(seconds: nil), "Try again shortly.")
    }

    func testRetryAfterHeaderSupportsHTTPDateFormat() async throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let future = Date().addingTimeInterval(48 * 3600)
        let headerValue = formatter.string(from: future)

        let httpClient = QueueHTTPClient([
            .json(#"{"error":{"status":429,"message":"Slow"}}"#, statusCode: 429, headers: ["Retry-After": headerValue]),
            .json(#"{"error":{"status":429,"message":"Slow"}}"#, statusCode: 429, headers: ["Retry-After": headerValue]),
            .json(#"{"error":{"status":429,"message":"Slow"}}"#, statusCode: 429, headers: ["Retry-After": headerValue])
        ])
        let client = SpotifyAPIClient(tokenProvider: FailingRefreshTokenProvider(), httpClient: httpClient)
        do {
            _ = try await client.currentUserProfile()
            XCTFail("Expected rate limited")
        } catch let error as SpotifyAPIError {
            guard case let .rateLimited(seconds) = error, let s = seconds else {
                return XCTFail("Expected rateLimited with interval")
            }
            XCTAssertGreaterThan(s, 24 * 3600)
            XCTAssertLessThan(s, 72 * 3600)
        }
    }

    func testRateLimitRetryEventuallySucceedsForGETRequests() async throws {
        let httpClient = QueueHTTPClient([
            .json(#"{"error":{"status":429,"message":"Slow 1"}}"#, statusCode: 429, headers: ["Retry-After": "0.001"]),
            .json(#"{"error":{"status":429,"message":"Slow 2"}}"#, statusCode: 429, headers: ["Retry-After": "0.001"]),
            .json("""
            {
              "id": "user-1",
              "display_name": "Recovered",
              "images": [],
              "country": "US",
              "product": "premium"
            }
            """)
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let profile = try await client.currentUserProfile()

        XCTAssertEqual(profile.displayName, "Recovered")
        XCTAssertEqual(httpClient.requests.count, 3, "Client should retry rate-limited GET requests up to the bounded retry budget.")
    }

    func testSearchDecodingSkipsNullEntriesInPagingItemsArrays() async throws {
        let httpClient = QueueHTTPClient([
            .json("""
            {
              "tracks": { "items": [null] },
              "artists": { "items": [] },
              "albums": { "items": [] },
              "playlists": {
                "items": [
                  {
                    "id": "playlist-0",
                    "name": "First",
                    "owner": { "id": "o", "display_name": "Owner" },
                    "images": [],
                    "items": { "total": 1 },
                    "snapshot_id": "s0"
                  },
                  null,
                  {
                    "id": "playlist-2",
                    "name": "Third",
                    "owner": { "id": "o", "display_name": "Owner" },
                    "images": [],
                    "items": { "total": 2 },
                    "snapshot_id": "s2"
                  }
                ]
              }
            }
            """)
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let results = try await client.search(query: "q", limit: 4)

        XCTAssertEqual(results.tracks.count, 0)
        XCTAssertEqual(results.playlists.map(\.id), ["playlist-0", "playlist-2"])
    }

    func testArtistDetailRequestAndDecoding() async throws {
        let httpClient = QueueHTTPClient([
            .json("""
            {
              "id": "ar1",
              "name": "Test Artist",
              "images": [],
              "followers": { "total": 42 },
              "genres": ["pop"],
              "uri": "spotify:artist:ar1"
            }
            """)
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let artist = try await client.artist(id: "ar1")

        XCTAssertEqual(httpClient.requests.first?.url?.absoluteString, "https://api.spotify.com/v1/artists/ar1")
        XCTAssertEqual(artist.id, "ar1")
        XCTAssertEqual(artist.name, "Test Artist")
        XCTAssertEqual(artist.followersTotal, 42)
        XCTAssertEqual(artist.genres, ["pop"])
    }

    func testArtistTopTracksPassesMarketQueryItem() async throws {
        let httpClient = QueueHTTPClient([
            .json(#"{"tracks":[]}"#)
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        _ = try await client.artistTopTracks(id: "ar1", market: "US")

        let url = try XCTUnwrap(httpClient.requests.first?.url?.absoluteString)
        XCTAssertTrue(url.contains("/v1/artists/ar1/top-tracks"))
        XCTAssertTrue(url.contains("market=US"))
    }

    func testAlbumTracksRequestsCorrectURLAndDecodes() async throws {
        let httpClient = QueueHTTPClient([
            .json("""
            {
              "href": "https://api.spotify.com/v1/albums/al1/tracks?offset=0&limit=50",
              "limit": 50,
              "next": null,
              "offset": 0,
              "previous": null,
              "total": 1,
              "items": [
                {
                  "id": "tr1",
                  "name": "Song",
                  "artists": [{ "id": "ar1", "name": "Artist" }],
                  "album": { "images": [] },
                  "duration_ms": 1000,
                  "explicit": false,
                  "uri": "spotify:track:tr1"
                }
              ]
            }
            """)
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let tracks = try await client.albumTracks(albumID: "al1", market: "US", limit: 50)

        let url = try XCTUnwrap(httpClient.requests.first?.url?.absoluteString)
        XCTAssertTrue(url.contains("/v1/albums/al1/tracks"))
        XCTAssertTrue(url.contains("market=US"))
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.id, "tr1")
        XCTAssertEqual(tracks.first?.name, "Song")
    }

    func testAlbumTracksConcurrentRequestsCoalesceByAlbumKey() async throws {
        let httpClient = DelayedCountingHTTPClient(
            responseJSON: """
            {
              "href": "https://api.spotify.com/v1/albums/al1/tracks?offset=0&limit=50",
              "limit": 50,
              "next": null,
              "offset": 0,
              "previous": null,
              "total": 1,
              "items": [
                {
                  "id": "tr1",
                  "name": "Song",
                  "artists": [{ "id": "ar1", "name": "Artist" }],
                  "album": { "images": [] },
                  "duration_ms": 1000,
                  "explicit": false,
                  "uri": "spotify:track:tr1"
                }
              ]
            }
            """
        )
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        async let first = client.albumTracks(albumID: "al1", market: "US", limit: 50)
        async let second = client.albumTracks(albumID: "al1", market: "US", limit: 50)
        let (a, b) = try await (first, second)

        XCTAssertEqual(a.map(\.id), ["tr1"])
        XCTAssertEqual(b.map(\.id), ["tr1"])
        let requestCount = await httpClient.requestCount
        XCTAssertEqual(requestCount, 1, "Concurrent identical album tracks requests should share one in-flight network call.")
    }

    func testAlbumTracksRespectsMaxPagesCap() async throws {
        let httpClient = QueueHTTPClient([
            .json("""
            {
              "href": "https://api.spotify.com/v1/albums/al1/tracks?offset=0&limit=2",
              "limit": 2,
              "next": "https://api.spotify.com/v1/albums/al1/tracks?offset=2&limit=2",
              "offset": 0,
              "previous": null,
              "total": 4,
              "items": [
                { "id": "tr1", "name": "S1", "artists": [], "album": {"images": []}, "duration_ms": 1, "explicit": false, "uri": "spotify:track:tr1" },
                { "id": "tr2", "name": "S2", "artists": [], "album": {"images": []}, "duration_ms": 1, "explicit": false, "uri": "spotify:track:tr2" }
              ]
            }
            """)
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let result = try await client.albumTracksWithMetrics(albumID: "al1", market: "US", limit: 2, maxPages: 1)

        XCTAssertEqual(result.pageRequests, 1, "maxPages cap should stop pagination after one HTTP call regardless of `next` URL.")
        XCTAssertEqual(result.tracks.map(\.id), ["tr1", "tr2"])
        XCTAssertEqual(httpClient.requests.count, 1)
    }

    func testAlbumsBatchedRequestEncodesIDsAndDecodes() async throws {
        let httpClient = QueueHTTPClient([
            .json("""
            {
              "albums": [
                {
                  "id": "al1",
                  "name": "Album One",
                  "images": [],
                  "tracks": {
                    "href": "x",
                    "limit": 50,
                    "next": null,
                    "offset": 0,
                    "previous": null,
                    "total": 1,
                    "items": [
                      {
                        "id": "tr1",
                        "name": "Song A",
                        "artists": [{ "id": "ar1", "name": "Artist" }],
                        "album": { "images": [] },
                        "duration_ms": 1000,
                        "explicit": false,
                        "uri": "spotify:track:tr1"
                      }
                    ]
                  }
                },
                null,
                {
                  "id": "al3",
                  "name": "Album Three",
                  "images": [],
                  "tracks": {
                    "href": "x",
                    "limit": 50,
                    "next": null,
                    "offset": 0,
                    "previous": null,
                    "total": 0,
                    "items": []
                  }
                }
              ]
            }
            """)
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let albums = try await client.albums(ids: ["al1", "al2", "al3"], market: "US")

        let url = try XCTUnwrap(httpClient.requests.first?.url?.absoluteString)
        XCTAssertTrue(url.contains("/v1/albums?"))
        XCTAssertTrue(url.contains("ids=al1,al2,al3") || url.contains("ids=al1%2Cal2%2Cal3"))
        XCTAssertTrue(url.contains("market=US"))
        XCTAssertEqual(albums.count, 2, "Null array entries (unknown IDs) must be dropped.")
        XCTAssertEqual(albums[0].id, "al1")
        XCTAssertEqual(albums[0].tracks.map(\.id), ["tr1"])
        XCTAssertTrue(albums[0].tracksAvailable)
        XCTAssertEqual(albums[1].id, "al3")
        XCTAssertTrue(albums[1].tracks.isEmpty)
        XCTAssertTrue(albums[1].tracksAvailable, "Empty `items` is still a present `tracks` paging object.")
    }

    func testAlbumsBatchedRejectsMoreThan20IDs() async {
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: QueueHTTPClient([]))
        let ids = (0..<21).map { "id-\($0)" }
        do {
            _ = try await client.albums(ids: ids, market: nil)
            XCTFail("Expected invalidRequest error")
        } catch let error as SpotifyAPIError {
            guard case .invalidRequest = error else {
                return XCTFail("Expected invalidRequest error, got \(error)")
            }
        } catch {
            XCTFail("Expected SpotifyAPIError, got \(error)")
        }
    }

    func testAlbumsBatchedNormalizesAndDeduplicatesIDsBeforeRequest() async throws {
        let httpClient = QueueHTTPClient([
            .json(#"{"albums":[]}"#)
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        _ = try await client.albums(ids: [" al1 ", "al1", "", "al2", "al2", "al3 "], market: nil)

        let url = try XCTUnwrap(httpClient.requests.first?.url?.absoluteString)
        XCTAssertTrue(url.contains("ids=al1,al2,al3") || url.contains("ids=al1%2Cal2%2Cal3"))
    }

    func testAlbumsBatchedConcurrentIdenticalNormalizedRequestsCoalesce() async throws {
        let httpClient = DelayedCountingHTTPClient(
            responseJSON: """
            {
              "albums": [
                {
                  "id": "al1",
                  "name": "Album One",
                  "images": [],
                  "tracks": {
                    "href": "x",
                    "limit": 50,
                    "next": null,
                    "offset": 0,
                    "previous": null,
                    "total": 0,
                    "items": []
                  }
                }
              ]
            }
            """
        )
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        async let first = client.albums(ids: [" al1 ", "al1"], market: "US")
        async let second = client.albums(ids: ["al1"], market: "US")
        let (a, b) = try await (first, second)

        XCTAssertEqual(a.map(\.id), ["al1"])
        XCTAssertEqual(b.map(\.id), ["al1"])
        let requestCount = await httpClient.requestCount
        XCTAssertEqual(requestCount, 1, "Concurrent normalized-equivalent batched album requests should share one in-flight HTTP call.")
    }

    func testAlbumsBatchedCacheKeySharesAcrossEquivalentIDOrdering() async throws {
        let cache = SpotifyGETResponseCache(diskCache: nil)
        let httpClient = QueueHTTPClient([
            .json("""
            {
              "albums": [
                {
                  "id": "al1",
                  "name": "Album One",
                  "images": [],
                  "tracks": {
                    "href": "x",
                    "limit": 50,
                    "next": null,
                    "offset": 0,
                    "previous": null,
                    "total": 0,
                    "items": []
                  }
                },
                {
                  "id": "al2",
                  "name": "Album Two",
                  "images": [],
                  "tracks": {
                    "href": "x",
                    "limit": 50,
                    "next": null,
                    "offset": 0,
                    "previous": null,
                    "total": 0,
                    "items": []
                  }
                }
              ]
            }
            """)
        ])
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"),
            httpClient: httpClient,
            getResponseCache: cache
        )

        _ = try await client.albums(ids: ["al1", "al2"], market: "US")
        _ = try await client.albums(ids: ["al2", "al1"], market: "US")

        XCTAssertEqual(httpClient.requests.count, 1, "Equivalent /v1/albums ids sets should share one GET cache key regardless of ordering.")
    }

    func testAlbumsBatchedSkipsInlineRetryWhenRetryAfterExceedsCap() async throws {
        // Spotify rate-limited with a long Retry-After must surface immediately so the per-artist
        // cooldown takes over instead of issuing 2–3 inline retries against the active back-off window.
        let httpClient = QueueHTTPClient([
            .json(
                #"{"error":{"status":429,"message":"Slow"}}"#,
                statusCode: 429,
                headers: ["Retry-After": "30"]
            )
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        do {
            _ = try await client.albums(ids: ["al1"], market: "US")
            XCTFail("Expected rateLimited error to propagate without inline retries.")
        } catch let error as SpotifyAPIError {
            guard case let .rateLimited(retryAfter) = error else {
                return XCTFail("Expected SpotifyAPIError.rateLimited, got \(error)")
            }
            XCTAssertEqual(retryAfter, 30, "Original Retry-After value must reach the caller's cooldown layer.")
        }
        XCTAssertEqual(httpClient.requests.count, 1, "Long Retry-After must short-circuit inline retries to a single outbound /v1/albums call.")
    }

    func testAlbumsBatchedRetriesShortRetryAfterUpToCap() async throws {
        // Short Retry-After values (≤ inlineRateLimitRetryCeiling) still allow the existing inline
        // retry path so transient 429s do not surface as user-visible errors. Sub-second value keeps
        // the test fast; the boundary is exercised in `testAlbumsBatchedSkipsInlineRetryWhenRetryAfterExceedsCap`.
        let httpClient = QueueHTTPClient([
            .json(
                #"{"error":{"status":429,"message":"Slow"}}"#,
                statusCode: 429,
                headers: ["Retry-After": "0.001"]
            ),
            .json("""
            {
              "albums": [
                {
                  "id": "al1",
                  "name": "Recovered",
                  "images": [],
                  "tracks": {
                    "href": "x",
                    "limit": 50,
                    "next": null,
                    "offset": 0,
                    "previous": null,
                    "total": 0,
                    "items": []
                  }
                }
              ]
            }
            """)
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let albums = try await client.albums(ids: ["al1"], market: "US")

        XCTAssertEqual(albums.map(\.id), ["al1"])
        XCTAssertEqual(httpClient.requests.count, 2, "Short Retry-After (≤ inlineRateLimitRetryCeiling) should retry exactly once and succeed.")
    }

    func testAlbumsBatchedServesStaleCacheOnRateLimitWithinStaleWindow() async throws {
        // Pre-populate a 100-second-expired cache entry under the canonical cache key so that when
        // the live call 429s, the stale-on-rate-limit fallback can resurface the prior body without
        // issuing additional outbound requests.
        let cache = SpotifyGETResponseCache(diskCache: nil)
        let staleBody = """
        {
          "albums": [
            {
              "id": "al1",
              "name": "Stale One",
              "images": [],
              "tracks": {
                "href": "x",
                "limit": 50,
                "next": null,
                "offset": 0,
                "previous": null,
                "total": 1,
                "items": [
                  {
                    "id": "stale-tr1",
                    "name": "Stale Track",
                    "artists": [{ "id": "ar1", "name": "Artist" }],
                    "album": { "images": [] },
                    "duration_ms": 1000,
                    "explicit": false,
                    "uri": "spotify:track:stale-tr1"
                  }
                ]
              }
            }
          ]
        }
        """
        let probeURL = URL(string: "https://api.spotify.com/v1/albums?ids=al1&market=US")!
        var probeRequest = URLRequest(url: probeURL)
        probeRequest.httpMethod = "GET"
        let cacheKey = try XCTUnwrap(SpotifyGETResponseCachePolicy.normalizedCacheKey(for: probeRequest))
        cache.store(body: Data(staleBody.utf8), cacheKey: cacheKey, ttl: -100)

        let httpClient = QueueHTTPClient([
            .json(
                #"{"error":{"status":429,"message":"Slow"}}"#,
                statusCode: 429,
                headers: ["Retry-After": "30"]
            )
        ])
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"),
            httpClient: httpClient,
            getResponseCache: cache
        )

        let albums = try await client.albums(ids: ["al1"], market: "US")

        XCTAssertEqual(httpClient.requests.count, 1, "Stale-on-rate-limit fallback must not re-attempt the live call.")
        XCTAssertEqual(albums.map(\.id), ["al1"])
        XCTAssertEqual(albums.first?.name, "Stale One", "Stale body should be decoded and returned.")
        XCTAssertEqual(albums.first?.tracks.map(\.id), ["stale-tr1"])
    }

    func testAlbumsBatchedRethrows429WhenNoStaleEntryWithinWindow() async throws {
        // No prior cache entry means stale-on-rate-limit cannot recover; the original 429 must
        // surface so caller-side cooldowns activate.
        let cache = SpotifyGETResponseCache(diskCache: nil)
        let httpClient = QueueHTTPClient([
            .json(
                #"{"error":{"status":429,"message":"Slow"}}"#,
                statusCode: 429,
                headers: ["Retry-After": "30"]
            )
        ])
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"),
            httpClient: httpClient,
            getResponseCache: cache
        )

        do {
            _ = try await client.albums(ids: ["al1"], market: "US")
            XCTFail("Expected rateLimited error when no stale cache entry exists.")
        } catch let error as SpotifyAPIError {
            guard case let .rateLimited(retryAfter) = error else {
                return XCTFail("Expected SpotifyAPIError.rateLimited, got \(error)")
            }
            XCTAssertEqual(retryAfter, 30)
        }
        XCTAssertEqual(httpClient.requests.count, 1)
    }

    func testAlbumsBatchedRethrows429WhenStaleEntryExceedsMaxAge() async throws {
        // Stale entries older than `batchedAlbumsStaleOnRateLimitMaxAge` (3600 s) must not be
        // resurrected; the 429 propagates so the caller can fall back to its empty-state path.
        let cache = SpotifyGETResponseCache(diskCache: nil)
        let probeURL = URL(string: "https://api.spotify.com/v1/albums?ids=al1&market=US")!
        var probeRequest = URLRequest(url: probeURL)
        probeRequest.httpMethod = "GET"
        let cacheKey = try XCTUnwrap(SpotifyGETResponseCachePolicy.normalizedCacheKey(for: probeRequest))
        cache.store(body: Data(#"{"albums":[]}"#.utf8), cacheKey: cacheKey, ttl: -(SpotifyAPIClient.batchedAlbumsStaleOnRateLimitMaxAge + 60))

        let httpClient = QueueHTTPClient([
            .json(
                #"{"error":{"status":429,"message":"Slow"}}"#,
                statusCode: 429,
                headers: ["Retry-After": "30"]
            )
        ])
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"),
            httpClient: httpClient,
            getResponseCache: cache
        )

        do {
            _ = try await client.albums(ids: ["al1"], market: "US")
            XCTFail("Expected rateLimited error when stale entry exceeds the bounded window.")
        } catch let error as SpotifyAPIError {
            guard case .rateLimited = error else {
                return XCTFail("Expected SpotifyAPIError.rateLimited, got \(error)")
            }
        }
        XCTAssertEqual(httpClient.requests.count, 1)
    }

    func testAlbumsBatchedNormalizedURLAlwaysEmitsMarket() async throws {
        // `nil`/empty market collapses onto the `from_token` cache + coalescer key; the outbound URL
        // must match so equivalent calls share one cache entry.
        let httpClient = QueueHTTPClient([
            .json(#"{"albums":[]}"#)
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        _ = try await client.albums(ids: ["al1"], market: nil)

        let url = try XCTUnwrap(httpClient.requests.first?.url?.absoluteString)
        XCTAssertTrue(
            url.contains("market=from_token"),
            "Outbound /v1/albums URL must always include the normalized market value (from_token when caller passes nil)."
        )
    }

    func testArtistAlbumsRequestsLimitTenAndPaginates() async throws {
        let httpClient = QueueHTTPClient([
            .json("""
            {
              "href": "https://api.spotify.com/v1/artists/ar1/albums?offset=0&limit=10",
              "limit": 10,
              "next": "https://api.spotify.com/v1/artists/ar1/albums?include_groups=album%2Csingle%2Ccompilation%2Cappears_on&limit=10&offset=10",
              "offset": 0,
              "previous": null,
              "total": 2,
              "items": [
                {
                  "id": "alb1",
                  "name": "First Album",
                  "images": [],
                  "release_date": "2020-01-01",
                  "total_tracks": 10,
                  "uri": "spotify:album:alb1",
                  "album_group": "album"
                }
              ]
            }
            """),
            .json("""
            {
              "href": "https://api.spotify.com/v1/artists/ar1/albums?offset=10&limit=10",
              "limit": 10,
              "next": null,
              "offset": 10,
              "previous": null,
              "total": 2,
              "items": [
                {
                  "id": "alb2",
                  "name": "Second Album",
                  "images": [],
                  "release_date": "2021-01-01",
                  "total_tracks": 8,
                  "uri": "spotify:album:alb2",
                  "album_group": "single"
                }
              ]
            }
            """)
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let albums = try await client.artistAlbums(id: "ar1")

        let firstURL = try XCTUnwrap(httpClient.requests.first?.url?.absoluteString)
        XCTAssertTrue(firstURL.contains("/v1/artists/ar1/albums"))
        XCTAssertTrue(firstURL.contains("limit=10"))
        XCTAssertFalse(firstURL.contains("limit=50"))
        XCTAssertEqual(albums.count, 2)
        XCTAssertEqual(albums.map(\.id), ["alb1", "alb2"])
    }

    func testArtistAlbumsPaginationStopsWhenNextURLRepeats() async throws {
        let loopingPage = """
            {
              "href": "https://api.spotify.com/v1/artists/ar1/albums?offset=0&limit=10",
              "limit": 10,
              "next": "https://api.spotify.com/v1/artists/ar1/albums?include_groups=album&limit=10&offset=10",
              "offset": 0,
              "previous": null,
              "total": 999,
              "items": [
                {
                  "id": "alb-loop",
                  "name": "Loop Album",
                  "images": [],
                  "release_date": "2020-01-01",
                  "total_tracks": 1,
                  "uri": "spotify:album:alb-loop",
                  "album_group": "album"
                }
              ]
            }
            """
        let responses = (0..<5).map { _ in QueueHTTPClient.Response.json(loopingPage) }
        let httpClient = QueueHTTPClient(responses)
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let albums = try await client.artistAlbums(id: "ar1", includeGroups: "album", limit: 10)

        XCTAssertEqual(httpClient.requests.count, 2, "A repeated next URL should break pagination before duplicate page storms.")
        XCTAssertEqual(albums.count, 2)
    }

    func testArtistAlbumsPaginationStillCapsAtTwentyPagesForUniqueNextURLs() async throws {
        let responses: [QueueHTTPClient.Response] = (0..<25).map { index in
            let next: String
            if index < 24 {
                next = "\"https://api.spotify.com/v1/artists/ar1/albums?include_groups=album&limit=10&offset=\((index + 1) * 10)\""
            } else {
                next = "null"
            }
            return .json("""
            {
              "href": "https://api.spotify.com/v1/artists/ar1/albums?offset=\(index * 10)&limit=10",
              "limit": 10,
              "next": \(next),
              "offset": \(index * 10),
              "previous": null,
              "total": 999,
              "items": [
                {
                  "id": "alb-\(index)",
                  "name": "Album \(index)",
                  "images": [],
                  "release_date": "2020-01-01",
                  "total_tracks": 1,
                  "uri": "spotify:album:alb-\(index)",
                  "album_group": "album"
                }
              ]
            }
            """)
        }
        let httpClient = QueueHTTPClient(responses)
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let albums = try await client.artistAlbums(id: "ar1", includeGroups: "album", limit: 10)

        XCTAssertEqual(httpClient.requests.count, 20, "Pagination should stop at the max page cap when next URLs are unique.")
        XCTAssertEqual(albums.count, 20)
    }

    func testBadRequestMapsToBadRequestCaseWithDiagnostics() async throws {
        let httpClient = QueueHTTPClient([
            .json("""
            { "error": { "status": 400, "message": "Invalid limit" } }
            """, statusCode: 400)
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        do {
            _ = try await client.currentUserProfile()
            XCTFail("Expected badRequest")
        } catch let error as SpotifyAPIError {
            guard case let .badRequest(message, details) = error else {
                return XCTFail("Expected badRequest, got \(error)")
            }
            XCTAssertEqual(message, "Invalid limit")
            XCTAssertTrue(details?.contains("GET https://api.spotify.com/v1/me") == true)
            XCTAssertTrue(details?.contains("HTTP 400") == true)
            XCTAssertTrue(details?.contains("\"message\": \"Invalid limit\"") == true)
        }
    }

    func testTrackDTOBuildsArtistRefsWhenSpotifyIncludesArtistIds() throws {
        let json = """
        {"id":"t1","name":"Song","artists":[{"id":"a1","name":"One"},{"id":"a2","name":"Two"}],"album":{"images":[]},"duration_ms":1000,"explicit":false,"uri":"spotify:track:t1"}
        """.data(using: .utf8)!
        let dto = try JSONDecoder().decode(SpotifyTrackDTO.self, from: json)
        let track = try XCTUnwrap(dto.domainModel())
        XCTAssertEqual(track.artistRefs.map(\.id), ["a1", "a2"])
        XCTAssertEqual(track.artists, ["One", "Two"])
    }

    func testErrorMappingCoversRateLimitForbiddenAuthDecodeAndNetwork() async throws {
        let rateLimited = QueueHTTPClient([
            .json("""
            { "error": { "status": 429, "message": "Slow down" } }
            """, statusCode: 429, headers: ["Retry-After": "7"]),
            .json("""
            { "error": { "status": 429, "message": "Slow down" } }
            """, statusCode: 429, headers: ["Retry-After": "7"]),
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

    func testConcurrentUnauthorizedRequestsShareSingleRefresh() async throws {
        let httpClient = TokenAwareUnauthorizedHTTPClient()
        let tokenProvider = SingleFlightRefreshingTokenProvider()
        let client = SpotifyAPIClient(tokenProvider: tokenProvider, httpClient: httpClient)

        async let first = client.currentUserProfile()
        async let second = client.currentUserProfile()
        let (a, b) = try await (first, second)
        let refreshCount = await tokenProvider.refreshCount

        XCTAssertEqual(a.displayName, "AfterRefresh")
        XCTAssertEqual(b.displayName, "AfterRefresh")
        XCTAssertEqual(refreshCount, 1, "Concurrent unauthorized requests should reuse one refresh flight.")
        XCTAssertEqual(httpClient.unauthorizedRequestCount, 2)
        XCTAssertEqual(httpClient.refreshedRequestCount, 2)
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
                artistRefs: [],
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

        let bundle = try XCTUnwrap(try cache.loadPlaylistsBundle(now: Date(timeIntervalSince1970: 1_400)))
        XCTAssertEqual(bundle.playlists, [playlist])
        XCTAssertEqual(bundle.age, 400, accuracy: 0.001)
        XCTAssertEqual(try cache.loadTracks(playlistID: "playlist-1", snapshotID: "snapshot-1", now: Date(timeIntervalSince1970: 1_100), maxAge: 300), [track])
        XCTAssertNil(try cache.loadTracks(playlistID: "playlist-1", snapshotID: "snapshot-2", now: Date(timeIntervalSince1970: 1_100), maxAge: 300))
        XCTAssertEqual(try cache.loadSettings(), CachedSpotifySettings(lastSelectedPlaylistID: "playlist-1", lastUserID: "user-1"))

        try cache.invalidateTracks(playlistID: "playlist-1")
        XCTAssertNil(try cache.loadTracks(playlistID: "playlist-1", snapshotID: "snapshot-1", now: Date(timeIntervalSince1970: 1_100), maxAge: 300))
    }

    func testServerErrorUsesPlainLanguageNotNSErrorCaseIndex() {
        let withoutMessage = SpotifyAPIError.server(statusCode: 502, message: nil, details: nil)
        XCTAssertTrue(withoutMessage.localizedDescription.contains("502"))
        XCTAssertTrue(withoutMessage.localizedDescription.lowercased().contains("try again"))
        XCTAssertFalse(withoutMessage.localizedDescription.contains("error 5"))
        XCTAssertEqual(withoutMessage.errorDescription, withoutMessage.userMessage)

        let withMessage = SpotifyAPIError.server(statusCode: 500, message: "Upstream timeout", details: nil)
        XCTAssertTrue(withMessage.localizedDescription.contains("500"))
        XCTAssertTrue(withMessage.localizedDescription.contains("Upstream timeout"))
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

/// `QueueHTTPClient` variant that awaits a `Task.yield()` (and a tiny sleep) after the first response
/// is dispatched. Lets a test observe the post-first-page state and cancel before subsequent pages
/// run, so we can verify pagination respects cancellation rather than racing all pages to completion.
private final class YieldAfterFirstResponseHTTPClient: HTTPClient {
    private var responses: [QueueHTTPClient.Response]
    private(set) var requests: [URLRequest] = []
    private var hasYielded = false

    init(_ responses: [QueueHTTPClient.Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if hasYielded {
            try await Task.sleep(nanoseconds: 50_000_000)
            try Task.checkCancellation()
        }
        requests.append(request)
        guard !responses.isEmpty else {
            throw URLError(.badServerResponse)
        }
        let response = responses.removeFirst()
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: response.headers
        )!
        if !hasYielded {
            hasYielded = true
            await Task.yield()
        }
        return (response.data, httpResponse)
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

private actor SingleFlightRefreshingTokenProvider: SpotifyAccessTokenProviding {
    private var inFlightRefresh: Task<String, Error>?
    private(set) var refreshCount = 0

    func accessToken() async throws -> String {
        "stale-token"
    }

    func refreshAccessTokenAfterUnauthorized() async throws -> String {
        if let inFlightRefresh {
            return try await inFlightRefresh.value
        }
        let task = Task<String, Error> {
            try await Task.sleep(nanoseconds: 100_000_000)
            return "fresh-token"
        }
        inFlightRefresh = task
        refreshCount += 1
        defer { inFlightRefresh = nil }
        return try await task.value
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

private actor DelayedCountingHTTPClient: HTTPClient {
    private let responseData: Data
    private(set) var requestCount: Int = 0

    init(responseJSON: String) {
        self.responseData = Data(responseJSON.utf8)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        try await Task.sleep(nanoseconds: 40_000_000)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [:]
        )!
        return (responseData, response)
    }
}

private final class TokenAwareUnauthorizedHTTPClient: HTTPClient {
    private let lock = NSLock()
    private(set) var unauthorizedRequestCount = 0
    private(set) var refreshedRequestCount = 0

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let statusCode: Int
        let payload: String

        lock.lock()
        if auth == "Bearer stale-token" {
            unauthorizedRequestCount += 1
            statusCode = 401
            payload = #"{"error":{"status":401,"message":"Expired"}}"#
        } else {
            refreshedRequestCount += 1
            statusCode = 200
            payload = #"{"id":"user-1","display_name":"AfterRefresh","images":[],"country":null,"product":"premium"}"#
        }
        lock.unlock()

        return (
            Data(payload.utf8),
            HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        )
    }
}
