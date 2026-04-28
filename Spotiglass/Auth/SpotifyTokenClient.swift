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
    case httpError(Int, String?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Spotify returned a response Spotiglass could not interpret."
        case let .httpError(status, description):
            if let description, !description.isEmpty {
                return "Spotify rejected the token request (HTTP \(status)): \(description)"
            }
            return "Spotify rejected the token request (HTTP \(status))."
        }
    }
}

struct SpotifyTokenClient {
    private let httpClient: HTTPClient
    private let now: () -> Date
    private let tokenEndpoint = URL(string: "https://accounts.spotify.com/api/token")!

    init(httpClient: HTTPClient = URLSession.shared, now: @escaping () -> Date = Date.init) {
        self.httpClient = httpClient
        self.now = now
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

        return try await sendTokenRequest(body: body)
    }

    private func sendTokenRequest(body: [URLQueryItem]) async throws -> SpotifyTokenGrant {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.formURLEncodedData()

        let (data, response) = try await httpClient.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            let error = try? JSONDecoder().decode(SpotifyTokenErrorResponse.self, from: data)
            throw SpotifyTokenClientError.httpError(response.statusCode, error?.errorDescription ?? error?.error)
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
