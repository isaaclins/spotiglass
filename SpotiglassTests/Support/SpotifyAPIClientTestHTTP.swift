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

    private var responses: [Response]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw URLError(.badServerResponse)
        }
        let response = responses.removeFirst()
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

    func refreshAccessTokenAfterUnauthorized() async throws -> String {
        refreshCount += 1
        return "fresh-token"
    }
}

actor SingleFlightRefreshingTokenProvider: SpotifyAccessTokenProviding {
    private var inFlightRefresh: Task<String, Error>?
    private let refreshStarted: AsyncSignal?
    private let releaseRefresh: AsyncSignal?
    private(set) var refreshCount = 0

    init(refreshStarted: AsyncSignal? = nil, releaseRefresh: AsyncSignal? = nil) {
        self.refreshStarted = refreshStarted
        self.releaseRefresh = releaseRefresh
    }

    func accessToken() async throws -> String {
        "stale-token"
    }

    func refreshAccessTokenAfterUnauthorized() async throws -> String {
        if let inFlightRefresh {
            return try await inFlightRefresh.value
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
        return try await task.value
    }
}

struct FailingRefreshTokenProvider: SpotifyAccessTokenProviding {
    func accessToken() async throws -> String {
        "token"
    }

    func refreshAccessTokenAfterUnauthorized() async throws -> String {
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

final class TokenAwareUnauthorizedHTTPClient: HTTPClient {
    private let lock = NSLock()
    private let unauthorizedRequestsReady: AsyncSignal?
    private(set) var unauthorizedRequestCount = 0
    private(set) var refreshedRequestCount = 0

    init(unauthorizedRequestsReady: AsyncSignal? = nil) {
        self.unauthorizedRequestsReady = unauthorizedRequestsReady
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let response = recordResponse(for: auth)
        if response.signalWhenReady {
            unauthorizedRequestsReady?.signal()
        }

        return (
            Data(response.payload.utf8),
            HTTPURLResponse(url: request.url!, statusCode: response.statusCode, httpVersion: nil, headerFields: nil)!
        )
    }

    private func recordResponse(for auth: String) -> (statusCode: Int, payload: String, signalWhenReady: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if auth == "Bearer stale-token" {
            unauthorizedRequestCount += 1
            return (
                statusCode: 401,
                payload: #"{"error":{"status":401,"message":"Expired"}}"#,
                signalWhenReady: unauthorizedRequestCount >= 2
            )
        }

        refreshedRequestCount += 1
        return (
            statusCode: 200,
            payload: #"{"id":"user-1","display_name":"AfterRefresh","images":[],"country":null,"product":"premium"}"#,
            signalWhenReady: false
        )
    }
}
