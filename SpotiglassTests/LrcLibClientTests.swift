import XCTest

@testable import Spotiglass

private final class LRCLIBStubURLProtocol: URLProtocol {
    static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1" && (request.url?.path.contains("/api/") == true)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        let body = """
        {"instrumental":false,"syncedLyrics":"[00:01.00]Test","plainLyrics":null}
        """.data(using: .utf8)!
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class LrcLibClientTests: XCTestCase {
    override func tearDown() {
        LRCLIBStubURLProtocol.requestCount = 0
        super.tearDown()
    }

    func testFetchLyricsStartsBothLRCLIBEndpoints() async throws {
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
        XCTAssertEqual(LRCLIBStubURLProtocol.requestCount, 2)
    }
}
