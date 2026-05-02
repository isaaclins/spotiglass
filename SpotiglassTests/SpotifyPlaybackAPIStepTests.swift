import XCTest
@testable import Spotiglass

@MainActor
final class SpotifyPlaybackAPIStepTests: XCTestCase {
    func testPlayURIRequestStartsAtZeroMilliseconds() async throws {
        let tokenProvider = StaticPlaybackAccessTokenProvider(token: "token")
        let httpClient = RecordingPlaybackHTTPClient()
        let api = SpotifyPlaybackAPI(
            baseURL: URL(string: "https://api.spotify.com")!,
            tokenProvider: tokenProvider,
            httpClient: httpClient
        )

        try await api.play(uri: "spotify:track:track-123", deviceID: "device-1")

        let request = try XCTUnwrap(httpClient.requests.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://api.spotify.com/v1/me/player/play?device_id=device-1"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["position_ms"] as? Int, 0)
        XCTAssertEqual(object["uris"] as? [String], ["spotify:track:track-123"])
    }

    func testPlayQueueRequestStartsFromZeroAndPreservesOrder() async throws {
        let tokenProvider = StaticPlaybackAccessTokenProvider(token: "token")
        let httpClient = RecordingPlaybackHTTPClient()
        let api = SpotifyPlaybackAPI(
            baseURL: URL(string: "https://api.spotify.com")!,
            tokenProvider: tokenProvider,
            httpClient: httpClient
        )

        try await api.play(
            uris: ["spotify:track:1", "spotify:episode:2", "spotify:track:3"],
            deviceID: "device-1"
        )

        let request = try XCTUnwrap(httpClient.requests.first)
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["position_ms"] as? Int, 0)
        XCTAssertEqual(
            object["uris"] as? [String],
            ["spotify:track:1", "spotify:episode:2", "spotify:track:3"]
        )
    }

    func testPlayQueueTrimsToSafeURIRequestLimit() async throws {
        let tokenProvider = StaticPlaybackAccessTokenProvider(token: "token")
        let httpClient = RecordingPlaybackHTTPClient()
        let api = SpotifyPlaybackAPI(
            baseURL: URL(string: "https://api.spotify.com")!,
            tokenProvider: tokenProvider,
            httpClient: httpClient
        )
        let oversized = (0..<130).map { "spotify:track:\($0)" }

        try await api.play(uris: oversized, deviceID: "device-1")

        let request = try XCTUnwrap(httpClient.requests.first)
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let uris = try XCTUnwrap(object["uris"] as? [String])
        XCTAssertEqual(uris.count, 100)
        XCTAssertEqual(uris.first, "spotify:track:0")
        XCTAssertEqual(uris.last, "spotify:track:99")
    }

    func testPlayContextURIEncodesContextURIField() async throws {
        let tokenProvider = StaticPlaybackAccessTokenProvider(token: "token")
        let httpClient = RecordingPlaybackHTTPClient()
        let api = SpotifyPlaybackAPI(
            baseURL: URL(string: "https://api.spotify.com")!,
            tokenProvider: tokenProvider,
            httpClient: httpClient
        )

        try await api.play(contextURI: "spotify:album:album-1", deviceID: "device-1")

        let request = try XCTUnwrap(httpClient.requests.first)
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["context_uri"] as? String, "spotify:album:album-1")
    }
}

@MainActor
private final class StaticPlaybackAccessTokenProvider: PlaybackAccessTokenProviding {
    let token: String

    init(token: String) {
        self.token = token
    }

    func playbackAccessToken() async throws -> String {
        token
    }

    func refreshedPlaybackAccessToken() async throws -> String {
        token
    }
}

private final class RecordingPlaybackHTTPClient: HTTPClient {
    private(set) var requests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (
            Data(),
            HTTPURLResponse(
                url: request.url!,
                statusCode: 204,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }
}
