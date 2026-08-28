import XCTest
@testable import Spotiglass

final class SpotifyAPIClientSearchAndHTTPTests: XCTestCase {
    func testHomeFeedRefreshCanBypassFreshResponseCache() async throws {
        let httpClient = QueueHTTPClient([
            .json(#"{"items":[]}"#),
            .json(#"{"items":[]}"#),
            .json(#"{"items":[]}"#),
            .json(#"{"items":[]}"#)
        ])
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"),
            httpClient: httpClient
        )

        _ = try await client.recentlyPlayedTracks(limit: 50, cacheMode: .freshOnly)
        _ = try await client.topTracks(limit: 20, timeRange: "short_term", cacheMode: .freshOnly)
        _ = try await client.recentlyPlayedTracks(limit: 50, cacheMode: .bypassCache)
        _ = try await client.topTracks(limit: 20, timeRange: "short_term", cacheMode: .bypassCache)

        XCTAssertEqual(httpClient.requests.count, 4)
    }

    func testTopArtistsClampsLimitAndMapsArtists() async throws {
        let httpClient = QueueHTTPClient([
            .json(#"{"items":[{"id":"artist-1","name":"Artist 1","images":[],"uri":"spotify:artist:artist-1"}],"total":1,"limit":50,"offset":0,"next":null}"#)
        ])
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"),
            httpClient: httpClient
        )

        let artists = try await client.topArtists(limit: 999, timeRange: "long_term")

        XCTAssertEqual(artists.map(\.id), ["artist-1"])
        XCTAssertEqual(
            httpClient.requests.first?.url?.absoluteString,
            "https://api.spotify.com/v1/me/top/artists?limit=50&time_range=long_term"
        )
    }

    func testFollowedArtistsFollowsAfterCursorUpToPageLimit() async throws {
        let next = "https://api.spotify.com/v1/me/following?type=artist&limit=50&after=artist-1"
        let httpClient = QueueHTTPClient([
            .json("""
            {"artists":{"items":[{"id":"artist-1","name":"Artist 1"}],"total":2,"limit":50,"next":"\(next)"}}
            """),
            .json("""
            {"artists":{"items":[{"id":"artist-2","name":"Artist 2"}],"total":2,"limit":50,"next":null}}
            """),
        ])
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"),
            httpClient: httpClient
        )

        let artists = try await client.followedArtists(limit: 50, maxPages: nil)

        XCTAssertEqual(artists.map(\.id), ["artist-1", "artist-2"])
        XCTAssertEqual(httpClient.requests.count, 2)
        XCTAssertEqual(httpClient.requests[1].url?.absoluteString, next)
    }

    func testArtistTopTracksMapsPlayableTracksAndMarket() async throws {
        let httpClient = QueueHTTPClient([
            .json("""
            {"tracks":[{"id":"track-1","name":"Track 1","artists":[{"id":"artist-1","name":"Artist 1"}],"album":{"id":"album-1","name":"Album","images":[]},"duration_ms":180000,"explicit":false,"is_playable":true,"uri":"spotify:track:track-1"}]}
            """),
        ])
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"),
            httpClient: httpClient
        )

        let tracks = try await client.artistTopTracks(id: "artist-1", market: "US")

        XCTAssertEqual(tracks.map(\.id), ["track-1"])
        XCTAssertEqual(
            httpClient.requests.first?.url?.absoluteString,
            "https://api.spotify.com/v1/artists/artist-1/top-tracks?market=US"
        )
    }

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
}
