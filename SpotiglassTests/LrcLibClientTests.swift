import XCTest

@testable import Spotiglass

private final class LRCLIBStubURLProtocol: URLProtocol {
    static var requestCount = 0
    static var requestedEndpoints: [String] = []
    static var responseByEndpoint: [String: (statusCode: Int, body: String)] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1" && (request.url?.path.contains("/api/") == true)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        let endpoint = request.url?.path.split(separator: "/").last.map(String.init) ?? "unknown"
        Self.requestedEndpoints.append(endpoint)
        let configured = Self.responseByEndpoint[endpoint]
            ?? (statusCode: 200, body: #"{"instrumental":false,"syncedLyrics":"[00:01.00]Test","plainLyrics":null}"#)
        let body = Data(configured.body.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: configured.statusCode, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class LrcLibClientTests: XCTestCase {
    override func tearDown() {
        LRCLIBStubURLProtocol.requestCount = 0
        LRCLIBStubURLProtocol.requestedEndpoints = []
        LRCLIBStubURLProtocol.responseByEndpoint = [:]
        super.tearDown()
    }

    func testFetchLyricsUsesCachedEndpointOnlyWhenUsable() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LRCLIBStubURLProtocol.self] + (config.protocolClasses ?? [])
        let session = URLSession(configuration: config)
        // Use http + loopback so App Transport Security does not block the request before our URLProtocol runs.
        let base = URL(string: "http://127.0.0.1:1")!
        let client = LrcLibClient(session: session, baseURL: base)
        let track = PlaybackNowPlaying(
            name: "Song",
            artists: ["A"],
            albumName: "Album",
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 0,
            uri: "spotify:track:abc123def456"
        )

        let lyrics: FetchedLyrics
        do {
            lyrics = try await client.fetchLyrics(for: track)
        } catch {
            return XCTFail("fetchLyrics threw: \(error)")
        }

        guard case let .synced(lines) = lyrics else {
            return XCTFail("expected synced lyrics, got \(lyrics)")
        }
        XCTAssertFalse(lines.isEmpty)
        XCTAssertEqual(LRCLIBStubURLProtocol.requestCount, 1)
        XCTAssertEqual(LRCLIBStubURLProtocol.requestedEndpoints, ["get-cached"])
    }

    func testFetchLyricsFallsBackToGetWhenGetCachedMissing() async throws {
        LRCLIBStubURLProtocol.responseByEndpoint["get-cached"] = (statusCode: 404, body: "")
        LRCLIBStubURLProtocol.responseByEndpoint["get"] = (
            statusCode: 200,
            body: #"{"instrumental":false,"syncedLyrics":"[00:01.00]Fallback","plainLyrics":null}"#
        )

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LRCLIBStubURLProtocol.self] + (config.protocolClasses ?? [])
        let session = URLSession(configuration: config)
        let base = URL(string: "http://127.0.0.1:1")!
        let client = LrcLibClient(session: session, baseURL: base)
        let track = PlaybackNowPlaying(
            name: "Song",
            artists: ["A"],
            albumName: "Album",
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 0,
            uri: "spotify:track:abc123def456"
        )

        let lyrics = try await client.fetchLyrics(for: track)
        guard case let .synced(lines) = lyrics else {
            return XCTFail("expected synced lyrics fallback, got \(lyrics)")
        }
        XCTAssertEqual(lines.first?.words, "Fallback")
        XCTAssertEqual(LRCLIBStubURLProtocol.requestCount, 2)
        XCTAssertEqual(LRCLIBStubURLProtocol.requestedEndpoints, ["get-cached", "get"])
    }

    func testFetchLyricsFallsBackToGetWhenCachedDecodingFails() async throws {
        LRCLIBStubURLProtocol.responseByEndpoint["get-cached"] = (statusCode: 200, body: #"{"instrumental": "broken"}"#)
        LRCLIBStubURLProtocol.responseByEndpoint["get"] = (
            statusCode: 200,
            body: #"{"instrumental":false,"syncedLyrics":"[00:01.00]FromFull","plainLyrics":null}"#
        )

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LRCLIBStubURLProtocol.self] + (config.protocolClasses ?? [])
        let session = URLSession(configuration: config)
        let base = URL(string: "http://127.0.0.1:1")!
        let client = LrcLibClient(session: session, baseURL: base)
        let track = PlaybackNowPlaying(
            name: "Song",
            artists: ["A"],
            albumName: "Album",
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 0,
            uri: "spotify:track:abc123def456"
        )

        let lyrics = try await client.fetchLyrics(for: track)
        guard case let .synced(lines) = lyrics else {
            return XCTFail("expected synced lyrics fallback, got \(lyrics)")
        }
        XCTAssertEqual(lines.first?.words, "FromFull")
        XCTAssertEqual(LRCLIBStubURLProtocol.requestedEndpoints, ["get-cached", "get"])
    }

    func testFetchLyricsRateLimitedCachedDoesNotEscalateToFullEndpoint() async {
        LRCLIBStubURLProtocol.responseByEndpoint["get-cached"] = (statusCode: 429, body: "")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LRCLIBStubURLProtocol.self] + (config.protocolClasses ?? [])
        let session = URLSession(configuration: config)
        let base = URL(string: "http://127.0.0.1:1")!
        let client = LrcLibClient(session: session, baseURL: base)
        let track = PlaybackNowPlaying(
            name: "Song",
            artists: ["A"],
            albumName: "Album",
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 0,
            uri: "spotify:track:abc123def456"
        )

        do {
            _ = try await client.fetchLyrics(for: track)
            XCTFail("Expected rate-limited failure")
        } catch let failure as LrcLibClient.Failure {
            guard case .rateLimited = failure else {
                return XCTFail("Expected .rateLimited, got \(failure)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(LRCLIBStubURLProtocol.requestedEndpoints, ["get-cached"])
    }
}
