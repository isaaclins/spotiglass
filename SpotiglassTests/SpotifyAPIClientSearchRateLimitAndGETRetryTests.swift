import XCTest
@testable import Spotiglass

final class SpotifyAPIClientSearchRateLimitAndGETRetryTests: XCTestCase {
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

    func testSearchRetainsPerCategoryPagingMetadata() async throws {
        let httpClient = QueueHTTPClient([
            .json("""
            {
              "tracks": {
                "limit": 10,
                "total": 31,
                "next": "https://api.spotify.com/v1/search?q=wide&type=track&limit=10&offset=10",
                "items": []
              }
            }
            """)
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let results = try await client.search(query: "wide", limit: 10)

        XCTAssertEqual(results.tracksPaging?.total, 31)
        XCTAssertEqual(
            results.tracksPaging?.next?.absoluteString,
            "https://api.spotify.com/v1/search?q=wide&type=track&limit=10&offset=10"
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

    func testSearchBypassCacheMakesSecondHTTPRequest() async throws {
        let searchJSON = """
            {
              "tracks": { "items": [] },
              "artists": { "items": [] },
              "albums": { "items": [] },
              "playlists": { "items": [] }
            }
            """
        let cache = SpotifyGETResponseCache(diskCache: nil)
        let httpClient = QueueHTTPClient([.json(searchJSON), .json(searchJSON)])
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"),
            httpClient: httpClient,
            getResponseCache: cache
        )

        _ = try await client.search(query: "Midnight", limit: 4, offset: 0, cacheMode: .freshOnly)
        _ = try await client.search(query: "Midnight", limit: 4, offset: 0, cacheMode: .bypassCache)

        XCTAssertEqual(httpClient.requests.count, 2)
    }

    func testLateSpotifyGETCompletionCannotOverwriteNewerBypassResponse() async throws {
        let oldJSON = #"{"id":"artist-1","name":"Old","images":[],"followers":{"total":1},"genres":[],"uri":"spotify:artist:artist-1"}"#
        let newJSON = #"{"id":"artist-1","name":"New","images":[],"followers":{"total":2},"genres":[],"uri":"spotify:artist:artist-1"}"#
        let root = spotiglassTestsTemporaryDirectory()
        let disk = try SpotifyLocalCache(rootDirectory: root)
        let cache = SpotifyGETResponseCache(diskCache: disk)
        let httpClient = OutOfOrderSpotifyGETHTTPClient()
        let client = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"),
            httpClient: httpClient,
            getResponseCache: cache
        )

        async let oldResult = client.artist(id: "artist-1", cacheMode: .freshOnly)
        await httpClient.waitUntilRequestCount(1)
        let refreshTask = Task {
            try await client.artist(id: "artist-1", cacheMode: .bypassCache)
        }
        await httpClient.waitUntilRequestCount(2)

        await httpClient.release(requestNumber: 2, body: Data(newJSON.utf8))
        let refreshed = try await refreshTask.value
        await httpClient.release(requestNumber: 1, body: Data(oldJSON.utf8))
        let delayed = try await oldResult

        XCTAssertEqual(refreshed.name, "New")
        XCTAssertEqual(delayed.name, "Old")

        let freshRead = try await client.artist(id: "artist-1", cacheMode: .freshOnly)
        XCTAssertEqual(freshRead.name, "New")
        let requestCount = await httpClient.requestCount
        XCTAssertEqual(requestCount, 2)

        let request = URLRequest(url: URL(string: "https://api.spotify.com/v1/artists/artist-1")!)
        let key = try XCTUnwrap(SpotifyGETResponseCachePolicy.normalizedCacheKey(for: request))
        let diskReader = SpotifyGETResponseCache(diskCache: disk)
        XCTAssertEqual(diskReader.cachedEntry(forCacheKey: key, allowExpired: false)?.data, Data(newJSON.utf8))
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
}

private actor OutOfOrderSpotifyGETHTTPClient: HTTPClient {
    private var requestCountValue = 0
    private var startWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var responseContinuations: [Int: CheckedContinuation<(Data, HTTPURLResponse), Error>] = [:]

    var requestCount: Int {
        requestCountValue
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            requestCountValue += 1
            let requestNumber = requestCountValue
            responseContinuations[requestNumber] = continuation
            let resumed = startWaiters.filter { $0.target <= requestCountValue }
            startWaiters.removeAll { $0.target <= requestCountValue }
            for waiter in resumed {
                waiter.continuation.resume()
            }
        }
    }

    func waitUntilRequestCount(_ target: Int) async {
        if requestCountValue >= target { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((target: target, continuation: continuation))
        }
    }

    func release(requestNumber: Int, body: Data) {
        guard let continuation = responseContinuations.removeValue(forKey: requestNumber) else {
            return
        }
        let response = HTTPURLResponse(
            url: URL(string: "https://api.spotify.com/v1/artists/artist-1")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        continuation.resume(returning: (body, response))
    }
}
