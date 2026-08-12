import XCTest
@testable import Spotiglass

@MainActor
final class SpotifyPlaybackAPITests: XCTestCase {
    private func makeAPI(_ responses: [QueueHTTPClient.Response]) -> (SpotifyPlaybackAPI, QueueHTTPClient, StaticPlaybackTokenProvider) {
        let http = QueueHTTPClient(responses)
        let token = StaticPlaybackTokenProvider(token: "tok")
        let api = SpotifyPlaybackAPI(tokenProvider: token, httpClient: http)
        return (api, http, token)
    }

    // MARK: - Simple PUT/POST endpoints

    func testTransferPlaybackEncodesDeviceIDsAndPlayFlag() async throws {
        let (api, http, _) = makeAPI([.json("", statusCode: 204)])

        try await api.transferPlayback(to: "dev-1", play: true)

        let req = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(req.httpMethod, "PUT")
        XCTAssertEqual(req.url?.path, "/v1/me/player")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(req.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["device_ids"] as? [String], ["dev-1"])
        XCTAssertEqual(json["play"] as? Bool, true)
    }

    func testPlayURIResetsPositionToZeroAndSendsDeviceQuery() async throws {
        let (api, http, _) = makeAPI([.json("", statusCode: 204)])

        try await api.play(uri: "spotify:track:abc", deviceID: "dev-x")

        let req = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(req.httpMethod, "PUT")
        XCTAssertEqual(req.url?.path, "/v1/me/player/play")
        XCTAssertTrue(req.url?.query?.contains("device_id=dev-x") ?? false)
        let body = try XCTUnwrap(req.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["uris"] as? [String], ["spotify:track:abc"])
        XCTAssertEqual(json["position_ms"] as? Int, 0)
    }

    func testPlayContextSendsContextURIBody() async throws {
        let (api, http, _) = makeAPI([.json("", statusCode: 204)])

        try await api.play(contextURI: "spotify:playlist:p1", deviceID: "dev-x")

        let req = try XCTUnwrap(http.requests.first)
        let body = try XCTUnwrap(req.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["context_uri"] as? String, "spotify:playlist:p1")
    }

    func testPlayURIListTruncatesAtMaxQueuedURIs() async throws {
        let (api, http, _) = makeAPI([.json("", statusCode: 204)])
        let uris = (0..<150).map { "spotify:track:t\($0)" }

        try await api.play(uris: uris, deviceID: "d")

        let req = try XCTUnwrap(http.requests.first)
        let body = try XCTUnwrap(req.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let sent = try XCTUnwrap(json["uris"] as? [String])
        XCTAssertEqual(sent.count, 100, "must clamp to maxQueuedURIs (100)")
        XCTAssertEqual(sent.first, "spotify:track:t0")
        XCTAssertEqual(sent.last, "spotify:track:t99")
    }

    func testPlayURIListEmptyThrowsInvalidRequest() async {
        let (api, _, _) = makeAPI([])
        do {
            try await api.play(uris: [], deviceID: "d")
            XCTFail("expected throw")
        } catch let error as SpotifyAPIError {
            // Expected case, nothing to assert beyond the match.
            if case .invalidRequest = error {} else { XCTFail("got \(error)") }
        } catch {
            XCTFail("wrong error type \(error)")
        }
    }

    func testSeekIncludesPositionMillisecondsQuery() async throws {
        let (api, http, _) = makeAPI([.json("", statusCode: 204)])

        try await api.seek(to: 42000, deviceID: "d1")

        let req = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(req.url?.path, "/v1/me/player/seek")
        let q = req.url?.query ?? ""
        XCTAssertTrue(q.contains("position_ms=42000"))
        XCTAssertTrue(q.contains("device_id=d1"))
    }

    func testNextAndPreviousUsePOST() async throws {
        let (api, http, _) = makeAPI([
            .json("", statusCode: 204),
            .json("", statusCode: 204)
        ])

        try await api.next(deviceID: "d")
        try await api.previous(deviceID: "d")

        XCTAssertEqual(http.requests[0].httpMethod, "POST")
        XCTAssertEqual(http.requests[0].url?.path, "/v1/me/player/next")
        XCTAssertEqual(http.requests[1].httpMethod, "POST")
        XCTAssertEqual(http.requests[1].url?.path, "/v1/me/player/previous")
    }

    func testAddToQueuePassesURIAndDeviceAsQueryItems() async throws {
        let (api, http, _) = makeAPI([.json("", statusCode: 204)])

        try await api.addToQueue(uri: "spotify:track:x", deviceID: "d-99")

        let req = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.path, "/v1/me/player/queue")
        let q = req.url?.query ?? ""
        XCTAssertTrue(q.contains("uri=spotify:track:x") || q.contains("uri=spotify%3Atrack%3Ax"))
        XCTAssertTrue(q.contains("device_id=d-99"))
    }

    func testSetShuffleSerializesBoolAsLowercaseString() async throws {
        let (api, http, _) = makeAPI([
            .json("", statusCode: 204),
            .json("", statusCode: 204)
        ])

        try await api.setShuffle(enabled: true, deviceID: "d")
        try await api.setShuffle(enabled: false, deviceID: "d")

        XCTAssertTrue(http.requests[0].url?.query?.contains("state=true") ?? false)
        XCTAssertTrue(http.requests[1].url?.query?.contains("state=false") ?? false)
    }

    func testSetRepeatSendsRawValueState() async throws {
        let (api, http, _) = makeAPI([
            .json("", statusCode: 204),
            .json("", statusCode: 204),
            .json("", statusCode: 204)
        ])

        try await api.setRepeat(mode: .off, deviceID: "d")
        try await api.setRepeat(mode: .context, deviceID: "d")
        try await api.setRepeat(mode: .track, deviceID: "d")

        XCTAssertTrue(http.requests[0].url?.query?.contains("state=off") ?? false)
        XCTAssertTrue(http.requests[1].url?.query?.contains("state=context") ?? false)
        XCTAssertTrue(http.requests[2].url?.query?.contains("state=track") ?? false)
    }

    // MARK: - GET endpoints

    func testFetchQueueDecodesTracksAndFiltersCurrentlyPlaying() async throws {
        let (api, _, _) = makeAPI([.json("""
        {
          "currently_playing": {
            "id": "cur",
            "name": "Now",
            "artists": [{"id":"a1","name":"A"}],
            "duration_ms": 100,
            "explicit": false,
            "uri": "spotify:track:cur"
          },
          "queue": [
            {
              "id": "cur",
              "name": "Now",
              "artists": [{"id":"a1","name":"A"}],
              "duration_ms": 100,
              "explicit": false,
              "uri": "spotify:track:cur"
            },
            {
              "id": "next1",
              "name": "Next",
              "artists": [{"id":"a2","name":"B"}],
              "duration_ms": 200,
              "explicit": true,
              "uri": "spotify:track:next1"
            }
          ]
        }
        """)])

        let response = try await api.fetchQueue()

        XCTAssertEqual(response.queue.count, 1, "currently-playing track must be filtered out of queue")
        if case let .track(t) = response.queue[0] {
            XCTAssertEqual(t.id, "next1")
        } else {
            XCTFail("expected track item")
        }
    }

    func testFetchQueueDecodesEpisodeViaShowDiscriminator() async throws {
        let (api, _, _) = makeAPI([.json("""
        {
          "currently_playing": null,
          "queue": [
            {
              "id": "ep1",
              "name": "Episode 1",
              "show": {"id":"s1","name":"Show","images":[]},
              "duration_ms": 600000,
              "uri": "spotify:episode:ep1"
            }
          ]
        }
        """)])

        let response = try await api.fetchQueue()

        XCTAssertEqual(response.queue.count, 1)
        if case let .episode(e) = response.queue[0] {
            XCTAssertEqual(e.id, "ep1")
            XCTAssertEqual(e.showName, "Show")
        } else {
            XCTFail("expected episode item")
        }
    }

    func testFetchPlayerSnapshotReturnsNilOn204() async throws {
        let (api, _, _) = makeAPI([.json("", statusCode: 204)])

        let snapshot = try await api.fetchPlayerSnapshot()

        XCTAssertNil(snapshot)
    }

    func testFetchPlayerSnapshotDecodesTransportAndActiveDevice() async throws {
        let (api, _, _) = makeAPI([.json("""
        {
          "shuffle_state": true,
          "repeat_state": "context",
          "is_playing": true,
          "device": {
            "id": "d1",
            "is_active": true,
            "is_restricted": false,
            "name": "MacBook",
            "type": "Computer"
          }
        }
        """)])

        let snapshot = try await api.fetchPlayerSnapshot()

        let unwrapped = try XCTUnwrap(snapshot)
        XCTAssertTrue(unwrapped.transport.shuffle)
        XCTAssertEqual(unwrapped.transport.repeatMode, .context)
        XCTAssertTrue(unwrapped.isPlaying)
        XCTAssertEqual(unwrapped.activeDevice?.deviceID, "d1")
        XCTAssertEqual(unwrapped.activeDevice?.name, "MacBook")
    }

    func testFetchPlayerSnapshotUnknownRepeatStateFallsBackToOff() async throws {
        let (api, _, _) = makeAPI([.json("""
        {"shuffle_state": false, "repeat_state": "bogus", "is_playing": false}
        """)])

        let snapshot = try await api.fetchPlayerSnapshot()

        XCTAssertEqual(snapshot?.transport.repeatMode, .off)
    }

    func testFetchAvailableDevicesDecodesList() async throws {
        let (api, _, _) = makeAPI([.json("""
        {"devices":[
          {"id":"d1","is_active":true,"is_restricted":false,"name":"A","type":"Computer"},
          {"id":"d2","is_active":false,"is_restricted":true,"name":"B","type":"Speaker"}
        ]}
        """)])

        let devices = try await api.fetchAvailableDevices()

        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0].deviceID, "d1")
        XCTAssertTrue(devices[0].isActive)
        XCTAssertTrue(devices[1].isRestricted)
    }

    // MARK: - Error mapping

    func testPostErrorMapping401_403_404_429_500() async {
        let cases: [(Int, [String: String], (SpotifyAPIError) -> Bool)] = [
            (401, [:], { if case .unauthorized = $0 { true } else { false } }),
            (403, [:], { if case .forbidden = $0 { true } else { false } }),
            (404, [:], { if case .notFound = $0 { true } else { false } }),
            (429, ["Retry-After": "3"], { if case let .rateLimited(retry) = $0 { retry == 3 } else { false } }),
            (500, [:], { if case .server = $0 { true } else { false } })
        ]
        for (status, headers, validate) in cases {
            let (api, _, _) = makeAPI([.json(
                #"{"error":{"status":\#(status),"message":"oops"}}"#,
                statusCode: status,
                headers: headers
            )])
            do {
                try await api.next(deviceID: "d")
                XCTFail("expected throw for \(status)")
            } catch let e as SpotifyAPIError {
                XCTAssertTrue(validate(e), "wrong mapping for \(status): \(e)")
            } catch {
                XCTFail("expected SpotifyAPIError for \(status), got \(error)")
            }
        }
    }

    func testRetryAfterHeaderHTTPDateFormatParsed() async {
        // Sat, 01 Jan 2050 00:00:00 GMT is well in the future relative to test execution.
        let (api, _, _) = makeAPI([.json(
            #"{"error":{"status":429,"message":"slow"}}"#,
            statusCode: 429,
            headers: ["Retry-After": "Sat, 01 Jan 2050 00:00:00 GMT"]
        )])
        do {
            try await api.next(deviceID: "d")
            XCTFail("expected throw")
        } catch let .rateLimited(retry) as SpotifyAPIError {
            XCTAssertNotNil(retry)
            XCTAssertGreaterThan(retry ?? 0, 0)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testMalformedRetryAfterHeaderReturnsNilRetry() async {
        let (api, _, _) = makeAPI([.json(
            #"{"error":{"status":429,"message":"slow"}}"#,
            statusCode: 429,
            headers: ["Retry-After": "not-a-number-or-date"]
        )])
        do {
            try await api.next(deviceID: "d")
            XCTFail("expected throw")
        } catch let .rateLimited(retry) as SpotifyAPIError {
            XCTAssertNil(retry)
        } catch {
            XCTFail("\(error)")
        }
    }

    // MARK: - GET retry (only for retryable paths)

    func testFetchPlayerSnapshotRetriesOn500ThenSucceeds() async throws {
        let (api, http, _) = makeAPI([
            .json(#"{"error":{"status":500,"message":"boom"}}"#, statusCode: 500),
            .json(#"{"shuffle_state":false,"repeat_state":"off","is_playing":false}"#)
        ])

        let snapshot = try await api.fetchPlayerSnapshot()

        XCTAssertNotNil(snapshot)
        XCTAssertEqual(http.requests.count, 2, "should retry once on 500")
    }

    func testFetchAvailableDevicesRetriesOn429UsingRetryAfter() async throws {
        let (api, http, _) = makeAPI([
            .json(#"{"error":{"status":429,"message":"slow"}}"#, statusCode: 429, headers: ["Retry-After": "0"]),
            .json(#"{"devices":[]}"#)
        ])

        _ = try await api.fetchAvailableDevices()

        XCTAssertEqual(http.requests.count, 2)
    }

    func testFetchQueueDoesNotRetryOn500_BecauseQueuePathIsNotInRetryList() async {
        let (api, http, _) = makeAPI([
            .json(#"{"error":{"status":500,"message":"boom"}}"#, statusCode: 500)
        ])

        do {
            _ = try await api.fetchQueue()
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(http.requests.count, 1, "fetchQueue must not retry")
        }
    }

    func testFetchPlayerSnapshotEventuallyFailsAfterMaxRetries() async {
        let (api, http, _) = makeAPI([
            .json(#"{"error":{"status":500,"message":"boom"}}"#, statusCode: 500, headers: ["Retry-After": "0"]),
            .json(#"{"error":{"status":500,"message":"boom"}}"#, statusCode: 500, headers: ["Retry-After": "0"]),
            .json(#"{"error":{"status":500,"message":"boom"}}"#, statusCode: 500, headers: ["Retry-After": "0"])
        ])

        do {
            _ = try await api.fetchPlayerSnapshot()
            XCTFail("expected throw")
        } catch let e as SpotifyAPIError {
            // Expected case, nothing to assert beyond the match.
            if case .server = e {} else { XCTFail("got \(e)") }
            XCTAssertEqual(http.requests.count, 3, "must give up after maxGETRetryAttempts")
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testFetchPlayerSnapshotRetriesOnTransientNetworkError() async throws {
        let http = FlakyThenJSONHTTPClient(
            failures: [URLError(.timedOut)],
            finalJSON: #"{"shuffle_state":false,"repeat_state":"off","is_playing":false}"#
        )
        let api = SpotifyPlaybackAPI(tokenProvider: StaticPlaybackTokenProvider(token: "t"), httpClient: http)

        let snapshot = try await api.fetchPlayerSnapshot()
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(http.attempts, 2)
    }

    func testFetchPlayerSnapshotCoalescesConcurrentCallers() async throws {
        let http = CountingDelayHTTPClient(
            delayNanoseconds: 100_000_000,
            json: #"{"shuffle_state":false,"repeat_state":"off","is_playing":false}"#
        )
        let api = SpotifyPlaybackAPI(tokenProvider: StaticPlaybackTokenProvider(token: "t"), httpClient: http)

        async let first = api.fetchPlayerSnapshot()
        async let second = api.fetchPlayerSnapshot()
        _ = try await (first, second)

        XCTAssertEqual(http.requestsStarted, 1, "Concurrent fetchPlayerSnapshot calls must share one GET /v1/me/player.")
    }

    func testFetchPlayerSnapshotPropagatesNonRetryableURLError() async {
        let http = AlwaysFailHTTPClient(error: URLError(.userAuthenticationRequired))
        let api = SpotifyPlaybackAPI(tokenProvider: StaticPlaybackTokenProvider(token: "t"), httpClient: http)
        do {
            _ = try await api.fetchPlayerSnapshot()
            XCTFail("expected throw")
        } catch let e as URLError {
            XCTAssertEqual(e.code, .userAuthenticationRequired)
        } catch {
            XCTFail("\(error)")
        }
    }
}

// MARK: - Test support

@MainActor
private final class StaticPlaybackTokenProvider: PlaybackAccessTokenProviding {
    let token: String
    init(token: String) { self.token = token }
    func playbackAccessToken() async throws -> String { token }
    func refreshedPlaybackAccessToken() async throws -> String { token }
}

private final class FlakyThenJSONHTTPClient: HTTPClient, @unchecked Sendable {
    private var failures: [Error]
    private let finalJSON: String
    private(set) var attempts: Int = 0

    init(failures: [Error], finalJSON: String) {
        self.failures = failures
        self.finalJSON = finalJSON
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        attempts += 1
        if !failures.isEmpty {
            throw failures.removeFirst()
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(finalJSON.utf8), resp)
    }
}

private final class AlwaysFailHTTPClient: HTTPClient, @unchecked Sendable {
    let error: Error
    init(error: Error) { self.error = error }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw error
    }
}

private final class CountingDelayHTTPClient: HTTPClient, @unchecked Sendable {
    private let delayNanoseconds: UInt64
    private let json: String
    private let lock = NSLock()
    private(set) var requestsStarted = 0

    init(delayNanoseconds: UInt64, json: String) {
        self.delayNanoseconds = delayNanoseconds
        self.json = json
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        requestsStarted += 1
        lock.unlock()
        try await Task.sleep(nanoseconds: delayNanoseconds)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(json.utf8), response)
    }
}
