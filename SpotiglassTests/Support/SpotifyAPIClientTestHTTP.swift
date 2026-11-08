import Foundation
import XCTest
@testable import Spotiglass

// swift-format-ignore: AlwaysUseLowerCamelCase
// Named like the XCTAssert family it belongs to, so it reads correctly at call sites.
func XCTAssertThrowsSpotifyAPIError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ expectedError: SpotifyAPIError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected \(expectedError)", file: file, line: line)
    } catch let error as SpotifyAPIError {
        XCTAssertEqual(error, expectedError, file: file, line: line)
    } catch {
        XCTFail("Expected SpotifyAPIError, got \(error)", file: file, line: line)
    }
}

final class QueueHTTPClient: HTTPClient {
    struct Response {
        let data: Data
        let statusCode: Int
        let headers: [String: String]

        static func json(_ string: String, statusCode: Int = 200, headers: [String: String] = [:]) -> Response {
            Response(data: Data(string.utf8), statusCode: statusCode, headers: headers)
        }

        static func data(_ data: Data, statusCode: Int = 200, headers: [String: String] = [:]) -> Response {
            Response(data: data, statusCode: statusCode, headers: headers)
        }
    }

    private let lock = NSLock()
    private var responses: [Response]
    private var recordedRequests: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { recordedRequests } }

    init(_ responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let next = lock.withLock { () -> Response? in
            recordedRequests.append(request)
            return responses.isEmpty ? nil : responses.removeFirst()
        }
        guard let response = next else {
            throw URLError(.badServerResponse)
        }
        return (
            response.data,
            HTTPURLResponse(
                url: request.url!,
                statusCode: response.statusCode,
                httpVersion: nil,
                headerFields: response.headers
            )!
        )
    }
}

/// Test double for network failure; distinct from `ThrowingHTTPClient` in `SpotifyAuthStepTests` (different initializer).
final class DisconnectedHTTPClient: HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

/// `QueueHTTPClient` variant that gives a test an explicit gate after the first response
/// is dispatched. This lets a test cancel before subsequent pages run, without racing a
/// wall-clock delay.
final class YieldAfterFirstResponseHTTPClient: HTTPClient {
    private var responses: [QueueHTTPClient.Response]
    private(set) var requests: [URLRequest] = []
    private var hasYielded = false
    private let firstRequestStarted: AsyncSignal?
    private let releaseFirstResponse: AsyncSignal?

    init(
        _ responses: [QueueHTTPClient.Response],
        firstRequestStarted: AsyncSignal? = nil,
        releaseFirstResponse: AsyncSignal? = nil
    ) {
        self.responses = responses
        self.firstRequestStarted = firstRequestStarted
        self.releaseFirstResponse = releaseFirstResponse
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if hasYielded {
            await Task.yield()
            try Task.checkCancellation()
        }
        requests.append(request)
        guard !responses.isEmpty else {
            throw URLError(.badServerResponse)
        }
        let response = responses.removeFirst()
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: response.headers
        )!
        if !hasYielded {
            hasYielded = true
            firstRequestStarted?.signal()
            if let releaseFirstResponse {
                await releaseFirstResponse.wait()
                try Task.checkCancellation()
            } else {
                await Task.yield()
            }
        }
        return (response.data, httpResponse)
    }
}

final class RefreshingTokenProvider: SpotifyAccessTokenProviding {
    private(set) var refreshCount = 0

    func accessToken() async throws -> String {
        "stale-token"
    }

    func refreshAccessTokenAfterUnauthorized(rejectedToken: String) async throws -> String {
        refreshCount += 1
        return "fresh-token"
    }
}

/// Follows the same contract as `AuthViewModel`: one refresh flight at a time,
/// and a 401 for a token that a finished refresh already replaced reuses the
/// new token instead of refreshing again.
actor SingleFlightRefreshingTokenProvider: SpotifyAccessTokenProviding {
    private var inFlightRefresh: Task<String, Error>?
    private var currentToken = "stale-token"
    private let refreshStarted: AsyncSignal?
    private let refreshJoined: AsyncSignal?
    private let releaseRefresh: AsyncSignal?
    private(set) var refreshCount = 0
    private(set) var joinedRefreshCount = 0

    init(
        refreshStarted: AsyncSignal? = nil,
        refreshJoined: AsyncSignal? = nil,
        releaseRefresh: AsyncSignal? = nil
    ) {
        self.refreshStarted = refreshStarted
        self.refreshJoined = refreshJoined
        self.releaseRefresh = releaseRefresh
    }

    func accessToken() async throws -> String {
        "stale-token"
    }

    func refreshAccessTokenAfterUnauthorized(rejectedToken: String) async throws -> String {
        if let inFlightRefresh {
            joinedRefreshCount += 1
            refreshJoined?.signal()
            return try await inFlightRefresh.value
        }
        if rejectedToken != currentToken {
            return currentToken
        }
        let refreshStarted = self.refreshStarted
        let releaseRefresh = self.releaseRefresh
        let task = Task<String, Error> {
            refreshStarted?.signal()
            await releaseRefresh?.wait()
            return "fresh-token"
        }
        inFlightRefresh = task
        refreshCount += 1
        defer { inFlightRefresh = nil }
        let token = try await task.value
        currentToken = token
        return token
    }
}

struct FailingRefreshTokenProvider: SpotifyAccessTokenProviding {
    func accessToken() async throws -> String {
        "token"
    }

    func refreshAccessTokenAfterUnauthorized(rejectedToken: String) async throws -> String {
        throw SpotifyAPIError.unauthorized
    }
}

actor DelayedCountingHTTPClient: HTTPClient {
    private let responseData: Data
    private let firstRequestStarted: AsyncSignal?
    private let releaseFirstRequest: AsyncSignal?
    private(set) var requestCount: Int = 0

    init(
        responseJSON: String,
        firstRequestStarted: AsyncSignal? = nil,
        releaseFirstRequest: AsyncSignal? = nil
    ) {
        self.responseData = Data(responseJSON.utf8)
        self.firstRequestStarted = firstRequestStarted
        self.releaseFirstRequest = releaseFirstRequest
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        if requestCount == 1 {
            firstRequestStarted?.signal()
            await releaseFirstRequest?.wait()
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [:]
        )!
        return (responseData, response)
    }
}

/// Answers 401 for `staleToken` and a profile for any other token. The first
/// 401 waits until a second request with the stale token has arrived, and that
/// second 401 is held until a request with a refreshed token has been served,
/// so it lands after the first request's refresh finished. That is the order
/// that refreshed twice in CI.
final class LateSecondUnauthorizedHTTPClient: HTTPClient {
    private let lock = NSLock()
    private let staleToken: String
    private let secondUnauthorizedArrived = AsyncSignal()
    private let refreshedRequestServed = AsyncSignal()
    private var recordedUnauthorizedCount = 0
    private var recordedAuthorizedCount = 0
    var unauthorizedRequestCount: Int { lock.withLock { recordedUnauthorizedCount } }
    var authorizedRequestCount: Int { lock.withLock { recordedAuthorizedCount } }

    init(staleToken: String) {
        self.staleToken = staleToken
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.bearerToken == staleToken {
            let arrival = lock.withLock { () -> Int in
                recordedUnauthorizedCount += 1
                return recordedUnauthorizedCount
            }
            if arrival == 1 {
                await secondUnauthorizedArrived.wait()
            } else {
                secondUnauthorizedArrived.signal()
                await refreshedRequestServed.wait()
            }
            return (
                Data(#"{"error":{"status":401,"message":"The access token expired"}}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            )
        }
        lock.withLock { recordedAuthorizedCount += 1 }
        refreshedRequestServed.signal()
        return (
            Data(#"{"id":"user-1","display_name":"AfterRefresh","images":[],"country":null,"product":"premium"}"#.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}

final class TokenAwareUnauthorizedHTTPClient: HTTPClient {
    private let lock = NSLock()
    private var recordedUnauthorizedCount = 0
    private var recordedRefreshedCount = 0
    var unauthorizedRequestCount: Int { lock.withLock { recordedUnauthorizedCount } }
    var refreshedRequestCount: Int { lock.withLock { recordedRefreshedCount } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let isStale = request.bearerToken == "stale-token"
        lock.withLock {
            if isStale {
                recordedUnauthorizedCount += 1
            } else {
                recordedRefreshedCount += 1
            }
        }
        let statusCode = isStale ? 401 : 200
        let payload = isStale
            ? #"{"error":{"status":401,"message":"Expired"}}"#
            : #"{"id":"user-1","display_name":"AfterRefresh","images":[],"country":null,"product":"premium"}"#
        return (
            Data(payload.utf8),
            HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        )
    }
}
