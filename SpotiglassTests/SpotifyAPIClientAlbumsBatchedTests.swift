import XCTest
@testable import Spotiglass

final class SpotifyAPIClientAlbumsBatchedTests: XCTestCase {
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
        XCTAssertEqual(albums.first?.tracks.first?.name, "Stale Track", "Stale body should be decoded and returned.")
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
}
