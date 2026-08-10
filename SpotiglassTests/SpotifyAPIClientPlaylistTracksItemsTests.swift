import XCTest

@testable import Spotiglass

final class SpotifyAPIClientPlaylistTracksItemsTests: XCTestCase {
    func testPlaylistTrackDecodingHandlesTrackEpisodeLocalUnavailableAndNull() async throws {
        let httpClient = QueueHTTPClient([
            .json(
                """
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
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let tracks = try await client.playlistTracks(playlistID: "playlist-1")

        XCTAssertEqual(tracks.count, 5)
        guard case .track(let track) = tracks[0].content else {
            return XCTFail("Expected track")
        }
        XCTAssertEqual(track.id, "track-1")
        XCTAssertEqual(track.artists, ["Artist One"])
        XCTAssertEqual(track.linkedFromID, "original-track")

        guard case .episode(let episode) = tracks[1].content else {
            return XCTFail("Expected episode")
        }
        XCTAssertEqual(episode.showName, "Show One")

        guard case .localTrack(let localTrack) = tracks[2].content else {
            return XCTFail("Expected local track")
        }
        XCTAssertEqual(localTrack.name, "Local Song")

        guard case .unavailable = tracks[3].content else {
            return XCTFail("Expected unavailable track")
        }
        guard case .unavailable = tracks[4].content else {
            return XCTFail("Expected unavailable null item")
        }

        XCTAssertEqual(
            httpClient.requests.first?.url?.absoluteString,
            "https://api.spotify.com/v1/playlists/playlist-1/items?limit=50&offset=0")
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
            .json(pageJSON(next: next2)),
        ])
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

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
            .json(page2),
        ])
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

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

    func testPlaylistTrackDecodingPrefersItemAndFallsBackToLegacyTrackField() async throws {
        let httpClient = QueueHTTPClient([
            .json(
                """
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
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let tracks = try await client.playlistTracks(playlistID: "playlist-1")

        XCTAssertEqual(tracks.count, 2)
        guard case .track(let primary) = tracks[0].content else {
            return XCTFail("Expected primary track from `item` field")
        }
        XCTAssertEqual(primary.id, "primary-track")
        XCTAssertEqual(primary.name, "Primary")

        guard case .track(let legacy) = tracks[1].content else {
            return XCTFail("Expected legacy track from fallback `track` field")
        }
        XCTAssertEqual(legacy.id, "legacy-track")
        XCTAssertEqual(legacy.name, "Legacy")
    }

    func testPlaylistTrackItemIDsAreUniqueWhenSameTrackAppearsTwice() async throws {
        let httpClient = QueueHTTPClient([
            .json(
                """
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
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let tracks = try await client.playlistTracks(playlistID: "playlist-1")

        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks[0].id, "dup-track:0")
        XCTAssertEqual(tracks[1].id, "dup-track:1")
        guard case .track(let a) = tracks[0].content, case .track(let b) = tracks[1].content else {
            return XCTFail("Expected two tracks")
        }
        XCTAssertEqual(a.id, "dup-track")
        XCTAssertEqual(b.id, "dup-track")
    }

    func testPlaylistTrackDecodingToleratesMissingSpotifyOptionalFields() async throws {
        let httpClient = QueueHTTPClient([
            .json(
                """
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
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let tracks = try await client.playlistTracks(playlistID: "playlist-1")

        XCTAssertEqual(tracks.count, 3)
        guard case .track(let track) = tracks[0].content else {
            return XCTFail("Expected sparse track")
        }
        XCTAssertEqual(track.name, "Sparse Track")
        XCTAssertEqual(track.artists, [])
        XCTAssertEqual(track.durationMilliseconds, 0)
        XCTAssertEqual(track.uri, "spotify:track:track-1")

        guard case .episode(let episode) = tracks[1].content else {
            return XCTFail("Expected sparse episode")
        }
        XCTAssertEqual(episode.name, "Unknown episode")
        XCTAssertEqual(episode.showName, nil)
        XCTAssertEqual(episode.uri, "spotify:episode:episode-1")

        guard case .unavailable = tracks[2].content else {
            return XCTFail("Expected unavailable item for missing track ID")
        }
    }
}
