import XCTest
@testable import Spotiglass

final class SpotifyTokenClientCoverageTests: XCTestCase {
    func testTokenClientErrorDescriptions() {
        XCTAssertEqual(
            SpotifyTokenClientError.invalidResponse.errorDescription,
            "Spotify returned a response Spotiglass could not interpret."
        )
        // The status code is a developer fact and stays on the error case for
        // the log, out of the sentence the user reads (#157).
        XCTAssertEqual(
            SpotifyTokenClientError.httpError(400, "Bad request", "invalid_grant", nil).errorDescription,
            "Spotify refused the sign-in: Bad request"
        )
        XCTAssertEqual(
            SpotifyTokenClientError.httpError(401, nil, "invalid_client", nil).errorDescription,
            "Spotify refused the sign-in: invalid_client"
        )
        XCTAssertEqual(
            SpotifyTokenClientError.httpError(500, nil, nil, nil).errorDescription,
            "Spotify refused the sign-in. Try connecting again."
        )
    }

    func testRefreshRetriesURLErrorThenSucceeds() async throws {
        let now = Date(timeIntervalSince1970: 5_000)
        let httpClient = SequencedTokenHTTPClientForCoverage([
            .failure(URLError(.networkConnectionLost)),
            .json("""
            {
              "access_token": "after-network",
              "token_type": "Bearer",
              "expires_in": 60
            }
            """, statusCode: 200)
        ])
        let client = SpotifyTokenClient(httpClient: httpClient, now: { now }, random: { _ in 0 })
        let grant = try await client.refreshAccessToken(clientID: "id", refreshToken: "rt")
        XCTAssertEqual(grant.accessToken, "after-network")
        XCTAssertEqual(httpClient.requestCount, 2)
    }

    func testRefreshRetries429WithRetryAfterHeader() async throws {
        let now = Date(timeIntervalSince1970: 6_000)
        let httpClient = SequencedTokenHTTPClientForCoverage([
            .json(#"{"error":"rate_limited"}"#, statusCode: 429, headers: ["Retry-After": "1"]),
            .json("""
            {
              "access_token": "after-429",
              "token_type": "Bearer",
              "expires_in": 120
            }
            """, statusCode: 200)
        ])
        let client = SpotifyTokenClient(
            httpClient: httpClient,
            now: { now },
            random: { _ in 0 },
            sleep: { _ in }
        )
        let grant = try await client.refreshAccessToken(clientID: "id", refreshToken: "rt")
        XCTAssertEqual(grant.accessToken, "after-429")
        XCTAssertEqual(httpClient.requestCount, 2)
    }

    func testRefresh429WithLongRetryAfterDoesNotScheduleEarlyRetry() async throws {
        let httpClient = SequencedTokenHTTPClientForCoverage([
            .json(#"{"error":"rate_limited"}"#, statusCode: 429, headers: ["Retry-After": "120"]),
            .json("""
            {
              "access_token": "after-long-429",
              "token_type": "Bearer",
              "expires_in": 120
            }
            """, statusCode: 200)
        ])
        let delays = RetryDelayRecorder()
        let client = SpotifyTokenClient(
            httpClient: httpClient,
            random: { _ in 0 },
            sleep: { delay in await delays.record(delay) }
        )

        let grant = try await client.refreshAccessToken(clientID: "id", refreshToken: "rt")
        let recordedDelays = await delays.values
        XCTAssertEqual(grant.accessToken, "after-long-429")
        XCTAssertEqual(recordedDelays, [120])
        XCTAssertEqual(httpClient.requestCount, 2)
    }

    func testRefresh429WithHTTPDateRetryAfterDoesNotScheduleEarlyRetry() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let httpClient = SequencedTokenHTTPClientForCoverage([
            .json(
                #"{"error":"rate_limited"}"#,
                statusCode: 429,
                headers: ["Retry-After": "Sun, 09 Sep 2001 01:48:40 GMT"]
            ),
            .json("""
            {
              "access_token": "after-date-429",
              "token_type": "Bearer",
              "expires_in": 120
            }
            """, statusCode: 200)
        ])
        let delays = RetryDelayRecorder()
        let client = SpotifyTokenClient(
            httpClient: httpClient,
            now: { now },
            random: { _ in 0 },
            sleep: { delay in await delays.record(delay) }
        )

        let grant = try await client.refreshAccessToken(clientID: "id", refreshToken: "rt")
        let recordedDelays = await delays.values
        XCTAssertEqual(grant.accessToken, "after-date-429")
        XCTAssertEqual(recordedDelays, [120])
        XCTAssertEqual(httpClient.requestCount, 2)
    }

    func testRefreshDoesNotRetryUnauthorizedClientErrors() async {
        let httpClient = SequencedTokenHTTPClientForCoverage([
            .json(#"{"error":"invalid_client"}"#, statusCode: 401),
            .json(#"{"access_token":"should-not-reach"}"#, statusCode: 200)
        ])
        let client = SpotifyTokenClient(httpClient: httpClient, random: { _ in 0 })
        do {
            _ = try await client.refreshAccessToken(clientID: "id", refreshToken: "rt")
            XCTFail("Expected failure")
        } catch let error as SpotifyTokenClientError {
            guard case let .httpError(status, _, oauthError, _) = error else {
                return XCTFail("Unexpected \(error)")
            }
            XCTAssertEqual(status, 401)
            XCTAssertEqual(oauthError, "invalid_client")
            XCTAssertEqual(httpClient.requestCount, 1)
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testTokenExchangeSurfacesHTTPErrorMetadata() async {
        let httpClient = HeaderAwareMockHTTPClient(
            data: #"{"error":"invalid_request","error_description":"Missing field"}"#.data(using: .utf8)!,
            statusCode: 400,
            headers: ["Retry-After": "9"]
        )
        let client = SpotifyTokenClient(httpClient: httpClient)
        do {
            _ = try await client.exchangeAuthorizationCode(
                clientID: "id",
                code: "code",
                codeVerifier: "verifier",
                redirectURI: URL(string: "http://127.0.0.1:43824/callback")!
            )
            XCTFail("Expected error")
        } catch let error as SpotifyTokenClientError {
            guard case let .httpError(status, description, oauthError, retryAfter) = error else {
                return XCTFail("Unexpected \(error)")
            }
            XCTAssertEqual(status, 400)
            XCTAssertEqual(description, "Missing field")
            XCTAssertEqual(oauthError, "invalid_request")
            XCTAssertEqual(retryAfter, 9)
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testGrantAuthenticatedSessionMapping() {
        let grant = SpotifyTokenGrant(
            accessToken: "a",
            tokenType: "Bearer",
            expiresAt: Date(timeIntervalSince1970: 100),
            refreshToken: "r",
            scope: "streaming"
        )
        let session = grant.authenticatedSession
        XCTAssertEqual(session.accessToken, "a")
        XCTAssertEqual(session.scope, "streaming")
    }
}

private actor RetryDelayRecorder {
    private(set) var values: [TimeInterval] = []

    func record(_ delay: TimeInterval) {
        values.append(delay)
    }
}

private final class HeaderAwareMockHTTPClient: HTTPClient {
    private let data: Data
    private let statusCode: Int
    private let headers: [String: String]

    init(data: Data, statusCode: Int, headers: [String: String] = [:]) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (
            data,
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: headers
            )!
        )
    }
}

private final class SequencedTokenHTTPClientForCoverage: HTTPClient {
    enum Step {
        case json(String, statusCode: Int = 200, headers: [String: String] = [:])
        case failure(Error)
    }

    private let lock = NSLock()
    private var steps: [Step]
    private(set) var requestCount = 0

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        requestCount += 1
        guard !steps.isEmpty else {
            lock.unlock()
            throw URLError(.badServerResponse)
        }
        let step = steps.removeFirst()
        lock.unlock()

        switch step {
        case let .failure(error):
            throw error
        case let .json(json, statusCode, headers):
            return (
                Data(json.utf8),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: headers
                )!
            )
        }
    }
}
