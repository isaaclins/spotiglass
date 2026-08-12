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

/// `QueueHTTPClient` variant that awaits a `Task.yield()` (and a tiny sleep) after the first response
/// is dispatched. Lets a test observe the post-first-page state and cancel before subsequent pages
/// run, so we can verify pagination respects cancellation rather than racing all pages to completion.
final class YieldAfterFirstResponseHTTPClient: HTTPClient {
    private var responses: [QueueHTTPClient.Response]
    private(set) var requests: [URLRequest] = []
    private var hasYielded = false

    init(_ responses: [QueueHTTPClient.Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if hasYielded {
            try await Task.sleep(nanoseconds: 50_000_000)
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
            await Task.yield()
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
    private(set) var refreshCount = 0

    func accessToken() async throws -> String {
        "stale-token"
    }

    func refreshAccessTokenAfterUnauthorized() async throws -> String {
        if let inFlightRefresh {
            return try await inFlightRefresh.value
        }
        let task = Task<String, Error> {
            try await Task.sleep(nanoseconds: 100_000_000)
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
    private(set) var requestCount: Int = 0

    init(responseJSON: String) {
        self.responseData = Data(responseJSON.utf8)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        try await Task.sleep(nanoseconds: 40_000_000)
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
    private(set) var unauthorizedRequestCount = 0
    private(set) var refreshedRequestCount = 0

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let statusCode: Int
        let payload: String

        lock.lock()
        if auth == "Bearer stale-token" {
            unauthorizedRequestCount += 1
            statusCode = 401
            payload = #"{"error":{"status":401,"message":"Expired"}}"#
        } else {
            refreshedRequestCount += 1
            statusCode = 200
            payload = #"{"id":"user-1","display_name":"AfterRefresh","images":[],"country":null,"product":"premium"}"#
        }
        lock.unlock()

        return (
            Data(payload.utf8),
            HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        )
    }
}
