import Foundation

protocol HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request, delegate: nil)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyTokenClientError.invalidResponse
        }
        return (data, httpResponse)
    }
}

struct SpotifyTokenGrant: Equatable {
    let accessToken: String
    let tokenType: String
    let expiresAt: Date
    let refreshToken: String?
    let scope: String?

    var authenticatedSession: AuthenticatedSession {
        AuthenticatedSession(
            accessToken: accessToken,
            tokenType: tokenType,
            scope: scope,
            expiresAt: expiresAt
        )
    }
}

enum SpotifyTokenClientError: Error, Equatable, LocalizedError {
    case invalidResponse
    case httpError(Int, String?, String?, TimeInterval?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Spotify returned a response Spotiglass could not interpret."
        case let .httpError(status, description, oauthError, _):
            if let description, !description.isEmpty {
                return "Spotify rejected the token request (HTTP \(status)): \(description)"
            }
            if let oauthError, !oauthError.isEmpty {
                return "Spotify rejected the token request (HTTP \(status)): \(oauthError)"
            }
            return "Spotify rejected the token request (HTTP \(status))."
        }
    }
}

struct SpotifyTokenClient {
    private let httpClient: HTTPClient
    private let now: () -> Date
    private let random: (ClosedRange<Double>) -> Double
    private let tokenEndpoint = URL(string: "https://accounts.spotify.com/api/token")!

    init(
        httpClient: HTTPClient = URLSession.shared,
        now: @escaping () -> Date = Date.init,
        random: @escaping (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
    ) {
        self.httpClient = httpClient
        self.now = now
        self.random = random
    }

    func exchangeAuthorizationCode(
        clientID: String,
        code: String,
        codeVerifier: String,
        redirectURI: URL
    ) async throws -> SpotifyTokenGrant {
        let body = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "code_verifier", value: codeVerifier)
        ]

        return try await sendTokenRequest(body: body)
    }

    func refreshAccessToken(clientID: String, refreshToken: String) async throws -> SpotifyTokenGrant {
        let body = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken)
        ]
        return try await sendRefreshTokenRequestWithRetry(body: body)
    }

    private func sendTokenRequest(body: [URLQueryItem]) async throws -> SpotifyTokenGrant {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.formURLEncodedData()

        let (data, response) = try await httpClient.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            let error = try? JSONDecoder().decode(SpotifyTokenErrorResponse.self, from: data)
            throw SpotifyTokenClientError.httpError(
                response.statusCode,
                error?.errorDescription ?? error?.error,
                error?.error,
                Self.retryAfter(from: response.allHeaderFields)
            )
        }

        let decoded = try JSONDecoder().decode(SpotifyTokenResponse.self, from: data)
        return SpotifyTokenGrant(
            accessToken: decoded.accessToken,
            tokenType: decoded.tokenType,
            expiresAt: now().addingTimeInterval(TimeInterval(decoded.expiresIn)),
            refreshToken: decoded.refreshToken,
            scope: decoded.scope
        )
    }

    private func sendRefreshTokenRequestWithRetry(body: [URLQueryItem]) async throws -> SpotifyTokenGrant {
        let maxAttempts = 3
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await sendTokenRequest(body: body)
            } catch {
                guard attempt < maxAttempts, shouldRetryRefresh(error) else {
                    throw error
                }
                let delay = retryDelay(forAttempt: attempt, error: error)
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func shouldRetryRefresh(_ error: Error) -> Bool {
        if let tokenError = error as? SpotifyTokenClientError,
           case let .httpError(status, _, oauthError, _) = tokenError {
            if status == 429 || (500...599).contains(status) {
                return true
            }
            if status == 400 || status == 401 {
                let normalized = oauthError?.lowercased() ?? ""
                if normalized == "invalid_grant"
                    || normalized == "invalid_client"
                    || normalized == "invalid_request"
                    || normalized == "unauthorized_client" {
                    return false
                }
            }
            return false
        }
        return (error as? URLError) != nil
    }

    private func retryDelay(forAttempt attempt: Int, error: Error) -> TimeInterval {
        let jitterUpperBound = min(pow(2.0, Double(attempt)), 5.0)
        let jitterDelay = random(0...jitterUpperBound)
        if let tokenError = error as? SpotifyTokenClientError,
           case let .httpError(status, _, _, retryAfter) = tokenError,
           status == 429,
           let retryAfter {
            return min(max(jitterDelay, retryAfter), 30)
        }
        return jitterDelay
    }

    private static func retryAfter(from headers: [AnyHashable: Any]) -> TimeInterval? {
        guard let raw = headers.first(where: {
            String(describing: $0.key).caseInsensitiveCompare("Retry-After") == .orderedSame
        })?.value as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let seconds = TimeInterval(trimmed), seconds >= 0 {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: trimmed) {
            return max(0, date.timeIntervalSinceNow)
        }
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        if let date = formatter.date(from: trimmed) {
            return max(0, date.timeIntervalSinceNow)
        }
        return nil
    }
}

private struct SpotifyTokenResponse: Decodable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int
    let refreshToken: String?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
    }
}

private struct SpotifyTokenErrorResponse: Decodable {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

private extension Array where Element == URLQueryItem {
    func formURLEncodedData() -> Data {
        var components = URLComponents()
        components.queryItems = self
        return Data((components.percentEncodedQuery ?? "").utf8)
    }
}
