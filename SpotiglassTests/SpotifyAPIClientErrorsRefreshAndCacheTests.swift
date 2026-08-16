import XCTest
@testable import Spotiglass

final class SpotifyAPIClientErrorsRefreshAndCacheTests: XCTestCase {
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
            httpClient: DisconnectedHTTPClient()
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
        let cache = try SpotifyLocalCache(rootDirectory: spotiglassTestsTemporaryDirectory())
        let playlist = SpotifyPlaylistSummary(
            id: "playlist-1",
            name: "Playlist",
                ownerID: "test-owner",
            ownerName: "Owner",
            imageURL: nil,
            trackCount: 1,
            snapshotID: "snapshot-1"
        )
        let track = SpotifyPlaylistTrackItem(
            id: "track-1",
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

        let freshBundle = try XCTUnwrap(try cache.loadPlaylistsBundle(now: Date(timeIntervalSince1970: 1_100)))
        XCTAssertEqual(freshBundle.playlists, [playlist])
        XCTAssertLessThanOrEqual(freshBundle.age, 300)

        let staleBundle = try XCTUnwrap(try cache.loadPlaylistsBundle(now: Date(timeIntervalSince1970: 1_400)))
        XCTAssertEqual(staleBundle.playlists, [playlist])
        XCTAssertGreaterThan(staleBundle.age, 300)
        XCTAssertEqual(try cache.loadTracks(playlistID: "playlist-1", snapshotID: "snapshot-1", now: Date(timeIntervalSince1970: 1_100), maxAge: 300), [track])
        XCTAssertNil(try cache.loadTracks(playlistID: "playlist-1", snapshotID: "snapshot-2", now: Date(timeIntervalSince1970: 1_100), maxAge: 300))
        try cache.invalidateTracks(playlistID: "playlist-1")
        XCTAssertNil(try cache.loadTracks(playlistID: "playlist-1", snapshotID: "snapshot-1", now: Date(timeIntervalSince1970: 1_100), maxAge: 300))
    }

    /// The message stays plain language; the status code and the server's own
    /// text are developer facts and now live in the diagnostics disclosure
    /// rather than in the sentence the listener reads.
    func testServerErrorUsesPlainLanguageNotNSErrorCaseIndex() {
        let withoutMessage = SpotifyAPIError.server(statusCode: 502, message: nil, details: nil)
        XCTAssertTrue(withoutMessage.localizedDescription.lowercased().contains("try again"))
        XCTAssertFalse(withoutMessage.localizedDescription.contains("error 5"))
        XCTAssertFalse(withoutMessage.localizedDescription.contains("502"))
        XCTAssertEqual(withoutMessage.errorDescription, withoutMessage.userMessage)
        XCTAssertEqual(withoutMessage.diagnosticDetails?.contains("502"), true)

        let withMessage = SpotifyAPIError.server(statusCode: 500, message: "Upstream timeout", details: nil)
        XCTAssertFalse(withMessage.localizedDescription.contains("500"))
        XCTAssertFalse(withMessage.localizedDescription.contains("Upstream timeout"))
        XCTAssertEqual(withMessage.diagnosticDetails?.contains("500"), true)
        XCTAssertEqual(withMessage.diagnosticDetails?.contains("Upstream timeout"), true)
    }
}
