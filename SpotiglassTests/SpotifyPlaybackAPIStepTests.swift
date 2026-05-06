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

    func testSetShuffleRequestUsesStateAndDeviceQueryItems() async throws {
        let tokenProvider = StaticPlaybackAccessTokenProvider(token: "token")
        let httpClient = SeqPlaybackHTTPClient(responses: [(Data(), 204)])
        let api = SpotifyPlaybackAPI(
            baseURL: URL(string: "https://api.spotify.com")!,
            tokenProvider: tokenProvider,
            httpClient: httpClient
        )

        try await api.setShuffle(enabled: true, deviceID: "device-1")

        let request = try XCTUnwrap(httpClient.requests.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        let url = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertTrue(url.hasPrefix("https://api.spotify.com/v1/me/player/shuffle?"))
        XCTAssertTrue(url.contains("state=true"))
        XCTAssertTrue(url.contains("device_id=device-1"))
    }

    func testSetRepeatRequestUsesStateAndDeviceQueryItems() async throws {
        let tokenProvider = StaticPlaybackAccessTokenProvider(token: "token")
        let httpClient = SeqPlaybackHTTPClient(responses: [(Data(), 204)])
        let api = SpotifyPlaybackAPI(
            baseURL: URL(string: "https://api.spotify.com")!,
            tokenProvider: tokenProvider,
            httpClient: httpClient
        )

        try await api.setRepeat(mode: .track, deviceID: "device-2")

        let request = try XCTUnwrap(httpClient.requests.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        let url = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertTrue(url.hasPrefix("https://api.spotify.com/v1/me/player/repeat?"))
        XCTAssertTrue(url.contains("state=track"))
        XCTAssertTrue(url.contains("device_id=device-2"))
    }

    func testFetchPlayerTransportReturnsNilOn204() async throws {
        let tokenProvider = StaticPlaybackAccessTokenProvider(token: "token")
        let httpClient = SeqPlaybackHTTPClient(responses: [(Data(), 204)])
        let api = SpotifyPlaybackAPI(
            baseURL: URL(string: "https://api.spotify.com")!,
            tokenProvider: tokenProvider,
            httpClient: httpClient
        )

        let transport = try await api.fetchPlayerTransport()
        XCTAssertNil(transport)
        let request = try XCTUnwrap(httpClient.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://api.spotify.com/v1/me/player")
    }

    func testFetchPlayerTransportDecodesShuffleAndRepeat() async throws {
        let tokenProvider = StaticPlaybackAccessTokenProvider(token: "token")
        let body = """
        {"shuffle_state":true,"repeat_state":"context"}
        """.data(using: .utf8)!
        let httpClient = SeqPlaybackHTTPClient(responses: [(body, 200)])
        let api = SpotifyPlaybackAPI(
            baseURL: URL(string: "https://api.spotify.com")!,
            tokenProvider: tokenProvider,
            httpClient: httpClient
        )

        let transport = try await api.fetchPlayerTransport()
        XCTAssertEqual(transport?.shuffle, true)
        XCTAssertEqual(transport?.repeatMode, .context)
    }

    func testFetchPlayerSnapshotDecodesNestedDevice() async throws {
        let tokenProvider = StaticPlaybackAccessTokenProvider(token: "token")
        let body = """
        {"shuffle_state":false,"repeat_state":"off","device":{"id":"dev1","is_active":true,"is_restricted":false,"name":"Kitchen","type":"speaker","volume_percent":50}}
        """.data(using: .utf8)!
        let httpClient = SeqPlaybackHTTPClient(responses: [(body, 200)])
        let api = SpotifyPlaybackAPI(
            baseURL: URL(string: "https://api.spotify.com")!,
            tokenProvider: tokenProvider,
            httpClient: httpClient
        )

        let snapshot = try await api.fetchPlayerSnapshot()
        XCTAssertEqual(snapshot?.transport.shuffle, false)
        XCTAssertEqual(snapshot?.transport.repeatMode, .off)
        XCTAssertEqual(snapshot?.activeDevice?.deviceID, "dev1")
        XCTAssertEqual(snapshot?.activeDevice?.name, "Kitchen")
        XCTAssertEqual(snapshot?.activeDevice?.volumePercent, 50)
        let request = try XCTUnwrap(httpClient.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.spotify.com/v1/me/player")
    }

    func testFetchAvailableDevicesDecodesResponse() async throws {
        let tokenProvider = StaticPlaybackAccessTokenProvider(token: "token")
        let body = """
        {"devices":[{"id":"a","is_active":false,"is_restricted":false,"name":"Mac","type":"computer","volume_percent":null}]}
        """.data(using: .utf8)!
        let httpClient = SeqPlaybackHTTPClient(responses: [(body, 200)])
        let api = SpotifyPlaybackAPI(
            baseURL: URL(string: "https://api.spotify.com")!,
            tokenProvider: tokenProvider,
            httpClient: httpClient
        )

        let devices = try await api.fetchAvailableDevices()
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.deviceID, "a")
        XCTAssertEqual(devices.first?.volumePercent, nil)
        let request = try XCTUnwrap(httpClient.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.spotify.com/v1/me/player/devices")
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

/// Returns queued `(body, statusCode)` pairs in order; defaults to 204 empty when exhausted.
private final class SeqPlaybackHTTPClient: HTTPClient {
    private(set) var requests: [URLRequest] = []
    private var responses: [(Data, Int)]

    init(responses: [(Data, Int)]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (data, code): (Data, Int)
        if responses.isEmpty {
            (data, code) = (Data(), 204)
        } else {
            (data, code) = responses.removeFirst()
        }
        return (
            data,
            HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        )
    }
}
