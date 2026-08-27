import XCTest
@testable import Spotiglass

final class SpotifyAPIClientArtistAndAlbumTracksTests: XCTestCase {
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

        let artist = try await client.artist(id: "ar1", cacheMode: .freshOnly)

        XCTAssertEqual(httpClient.requests.first?.url?.absoluteString, "https://api.spotify.com/v1/artists/ar1")
        XCTAssertEqual(artist.id, "ar1")
        XCTAssertEqual(artist.name, "Test Artist")
        XCTAssertEqual(artist.followersTotal, 42)
        XCTAssertEqual(artist.genres, ["pop"])
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

    func testAlbumTracksFirstPageDoesNotJoinAConcurrentMultiPageRequest() async throws {
        func page(trackID: String, next: String?) -> String {
            let nextJSON = next.map { "\"\($0)\"" } ?? "null"
            return """
            {
              "href": "https://api.spotify.com/v1/albums/al1/tracks",
              "limit": 1,
              "next": \(nextJSON),
              "offset": 0,
              "previous": null,
              "total": 2,
              "items": [
                {
                  "id": "\(trackID)",
                  "name": "Song \(trackID)",
                  "artists": [{ "id": "ar1", "name": "Artist" }],
                  "album": { "images": [] },
                  "duration_ms": 1000,
                  "explicit": false,
                  "uri": "spotify:track:\(trackID)"
                }
              ]
            }
            """
        }
        let next = "https://api.spotify.com/v1/albums/al1/tracks?offset=1&limit=1"
        let firstRequestStarted = AsyncSignal()
        let releaseFirstRequest = AsyncSignal()
        let httpClient = AlbumTracksPageRoutingHTTPClient(
            firstPage: page(trackID: "tr1", next: next),
            secondPage: page(trackID: "tr2", next: nil),
            firstRequestStarted: firstRequestStarted,
            releaseFirstRequest: releaseFirstRequest
        )
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)
        let fullTask = Task {
            try await client.albumTracks(albumID: "al1", market: "US", limit: 1, maxPages: 2)
        }
        let didStartFirstRequest = await firstRequestStarted.wait(timeout: .seconds(1))
        XCTAssertTrue(
            didStartFirstRequest,
            "the multi-page request should start before the first-page request"
        )

        let firstPage = try await client.albumTracksFirstPage(albumID: "al1", market: "US", limit: 1)
        releaseFirstRequest.signal()
        let full = try await fullTask.value

        XCTAssertEqual(firstPage.map(\.id), ["tr1"])
        XCTAssertEqual(full.map(\.id), ["tr1", "tr2"])
        let requestCount = await httpClient.requestCount
        XCTAssertEqual(requestCount, 3)
    }

    func testAlbumTracksConcurrentRequestsCoalesceByAlbumKey() async throws {
        let requestStarted = AsyncSignal()
        let releaseRequest = AsyncSignal()
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
            """,
            firstRequestStarted: requestStarted,
            releaseFirstRequest: releaseRequest
        )
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        async let first = client.albumTracks(albumID: "al1", market: "US", limit: 50)
        let didStartRequest = await requestStarted.wait(timeout: .seconds(1))
        XCTAssertTrue(
            didStartRequest,
            "the coalesced album request should start before releasing the response"
        )
        async let second = client.albumTracks(albumID: "al1", market: "US", limit: 50)
        releaseRequest.signal()
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

        XCTAssertEqual(result.tracks.map(\.id), ["tr1", "tr2"])
        XCTAssertEqual(httpClient.requests.count, 1, "maxPages cap should stop pagination after one HTTP call regardless of `next` URL.")
    }
}

private actor AlbumTracksPageRoutingHTTPClient: HTTPClient {
    private let firstPage: Data
    private let secondPage: Data
    private let firstRequestStarted: AsyncSignal
    private let releaseFirstRequest: AsyncSignal
    private(set) var requestCount = 0

    init(
        firstPage: String,
        secondPage: String,
        firstRequestStarted: AsyncSignal,
        releaseFirstRequest: AsyncSignal
    ) {
        self.firstPage = Data(firstPage.utf8)
        self.secondPage = Data(secondPage.utf8)
        self.firstRequestStarted = firstRequestStarted
        self.releaseFirstRequest = releaseFirstRequest
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        if requestCount == 1 {
            firstRequestStarted.signal()
            await releaseFirstRequest.wait()
        }
        let isSecondPage = request.url?.query?.contains("offset=1") == true
        let data = isSecondPage ? secondPage : firstPage
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}
