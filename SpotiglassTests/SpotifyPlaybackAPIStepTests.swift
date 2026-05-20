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

    func testFetchPlayerSnapshotReturnsNilOn204() async throws {
        let tokenProvider = StaticPlaybackAccessTokenProvider(token: "token")
        let httpClient = SeqPlaybackHTTPClient(responses: [(Data(), 204)])
        let api = SpotifyPlaybackAPI(
            baseURL: URL(string: "https://api.spotify.com")!,
            tokenProvider: tokenProvider,
            httpClient: httpClient
        )

        let snapshot = try await api.fetchPlayerSnapshot()
        XCTAssertNil(snapshot)
        let request = try XCTUnwrap(httpClient.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://api.spotify.com/v1/me/player")
    }

    func testFetchPlayerSnapshotDecodesShuffleAndRepeatFromTransport() async throws {
        let tokenProvider = StaticPlaybackAccessTokenProvider(token: "token")
        let body = """
        {"shuffle_state":true,"repeat_state":"context","is_playing":true}
        """.data(using: .utf8)!
        let httpClient = SeqPlaybackHTTPClient(responses: [(body, 200)])
        let api = SpotifyPlaybackAPI(
            baseURL: URL(string: "https://api.spotify.com")!,
            tokenProvider: tokenProvider,
            httpClient: httpClient
        )

        let snapshot = try await api.fetchPlayerSnapshot()
        XCTAssertEqual(snapshot?.transport.shuffle, true)
        XCTAssertEqual(snapshot?.transport.repeatMode, .context)
    }

    func testFetchPlayerSnapshotDecodesNestedDevice() async throws {
        let tokenProvider = StaticPlaybackAccessTokenProvider(token: "token")
        let body = """
        {"shuffle_state":false,"repeat_state":"off","is_playing":true,"device":{"id":"dev1","is_active":true,"is_restricted":false,"name":"Kitchen","type":"speaker","volume_percent":50}}
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
        XCTAssertEqual(snapshot?.isPlaying, true)
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
        let request = try XCTUnwrap(httpClient.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.spotify.com/v1/me/player/devices")
    }

    func testFetchAvailableDevicesRetriesOnRateLimitThenSucceeds() async throws {
        let tokenProvider = StaticPlaybackAccessTokenProvider(token: "token")
        let body = """
        {"devices":[{"id":"b","is_active":true,"is_restricted":false,"name":"Desk","type":"computer","volume_percent":20}]}
        """.data(using: .utf8)!
        let httpClient = SeqPlaybackHTTPClient(responses: [
            (Data(#"{"error":{"status":429,"message":"Slow down"}}"#.utf8), 429),
            (Data(#"{"error":{"status":429,"message":"Still slow"}}"#.utf8), 429),
            (body, 200)
        ])
        let api = SpotifyPlaybackAPI(
            baseURL: URL(string: "https://api.spotify.com")!,
            tokenProvider: tokenProvider,
            httpClient: httpClient
        )

        let devices = try await api.fetchAvailableDevices()

        XCTAssertEqual(devices.map(\.deviceID), ["b"])
        XCTAssertEqual(httpClient.requests.count, 3, "Devices GET should retry rate limits with a bounded budget.")
    }

    func testFetchAvailableDevicesRetryBudgetIsBounded() async throws {
        let tokenProvider = StaticPlaybackAccessTokenProvider(token: "token")
        let httpClient = SeqPlaybackHTTPClient(responses: [
            (Data(#"{"error":{"status":500,"message":"Oops 1"}}"#.utf8), 500),
            (Data(#"{"error":{"status":500,"message":"Oops 2"}}"#.utf8), 500),
            (Data(#"{"error":{"status":500,"message":"Oops 3"}}"#.utf8), 500),
            (Data(#"{"error":{"status":500,"message":"Oops 4"}}"#.utf8), 500)
        ])
        let api = SpotifyPlaybackAPI(
            baseURL: URL(string: "https://api.spotify.com")!,
            tokenProvider: tokenProvider,
            httpClient: httpClient
        )

        do {
            _ = try await api.fetchAvailableDevices()
            XCTFail("Expected server error")
        } catch let error as SpotifyAPIError {
            guard case .server = error else {
                return XCTFail("Expected server error, got \(error)")
            }
        }
        XCTAssertEqual(httpClient.requests.count, 3, "Retry attempts must be capped.")
    }

    func testFetchQueueDoesNotRetryOnRateLimit() async throws {
        let tokenProvider = StaticPlaybackAccessTokenProvider(token: "token")
        let httpClient = SeqPlaybackHTTPClient(headerResponses: [
            (Data(#"{"error":{"status":429,"message":"Slow"}}"#.utf8), 429, ["Retry-After": "7"])
        ])
        let api = SpotifyPlaybackAPI(
            baseURL: URL(string: "https://api.spotify.com")!,
            tokenProvider: tokenProvider,
            httpClient: httpClient
        )

        do {
            _ = try await api.fetchQueue()
            XCTFail("Expected rate-limited error")
        } catch let error as SpotifyAPIError {
            guard case let .rateLimited(retryAfter) = error else {
                return XCTFail("Expected rate-limited error, got \(error)")
            }
            XCTAssertEqual(retryAfter ?? 0, 7, accuracy: 0.001)
        }
        XCTAssertEqual(httpClient.requests.count, 1, "Non-device/player GET endpoints should not use playback retry loop.")
    }

    func testFetchPlayerSnapshotRetriesTransientNetworkFailures() async throws {
        let tokenProvider = StaticPlaybackAccessTokenProvider(token: "token")
        let body = """
        {"shuffle_state":false,"repeat_state":"off","is_playing":true}
        """.data(using: .utf8)!
        let httpClient = FlakyPlaybackHTTPClient(
            failuresBeforeSuccess: 2,
            successStatusCode: 200,
            successBody: body
        )
        let api = SpotifyPlaybackAPI(
            baseURL: URL(string: "https://api.spotify.com")!,
            tokenProvider: tokenProvider,
            httpClient: httpClient
        )

        let snapshot = try await api.fetchPlayerSnapshot()

        XCTAssertEqual(snapshot?.transport.repeatMode, .off)
        XCTAssertEqual(httpClient.requestCount, 3, "Player snapshot GET should retry transient network errors with a cap.")
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
    private var responses: [(Data, Int, [String: String]?)]

    init(responses: [(Data, Int)]) {
        self.responses = responses.map { ($0.0, $0.1, nil) }
    }

    init(headerResponses: [(Data, Int, [String: String]?)]) {
        self.responses = headerResponses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (data, code, headers): (Data, Int, [String: String]?)
        if responses.isEmpty {
            (data, code, headers) = (Data(), 204, nil)
        } else {
            (data, code, headers) = responses.removeFirst()
        }
        return (
            data,
            HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!
        )
    }
}

private final class FlakyPlaybackHTTPClient: HTTPClient {
    private var remainingFailures: Int
    private let successStatusCode: Int
    private let successBody: Data
    private(set) var requestCount: Int = 0

    init(failuresBeforeSuccess: Int, successStatusCode: Int, successBody: Data) {
        self.remainingFailures = failuresBeforeSuccess
        self.successStatusCode = successStatusCode
        self.successBody = successBody
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw URLError(.timedOut)
        }
        return (
            successBody,
            HTTPURLResponse(url: request.url!, statusCode: successStatusCode, httpVersion: nil, headerFields: nil)!
        )
    }
}
