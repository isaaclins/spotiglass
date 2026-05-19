import XCTest
@testable import Spotiglass

@MainActor
final class AuthViewModelCoverageTests: XCTestCase {
    func testClientIDDidSetPersistsToSettings() {
        let suite = "SpotiglassTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SpotifyAuthSettings(defaults: defaults)
        let viewModel = AuthViewModel(settings: settings, refreshTokenStore: InMemoryRefreshTokenStore())

        viewModel.clientID = "  trimmed-id  "

        XCTAssertEqual(settings.clientID, "trimmed-id")
    }

    func testPlaybackAccessTokenReturnsCurrentSessionWhenNotExpiring() async throws {
        let redirect = URL(string: "http://127.0.0.1:43824/callback")!
        let codeVerifier = try PKCE.makeCodeVerifier()
        let flow = ImmediateAuthorizationFlow(
            code: SpotifyAuthorizationCode(code: "code", codeVerifier: codeVerifier, redirectURI: redirect)
        )
        let now = Date()
        let grantJSON = """
        {
          "access_token": "live-token",
          "token_type": "Bearer",
          "expires_in": 3600,
          "refresh_token": "refresh-token",
          "scope": "playlist-read-private playlist-read-collaborative user-library-read streaming"
        }
        """
        let httpClient = QueueHTTPClient([
            .json(grantJSON),
            .json(grantJSON)
        ])
        let viewModel = AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            authorizationFlow: flow,
            tokenClient: SpotifyTokenClient(httpClient: httpClient, now: { now }),
            refreshTokenStore: InMemoryRefreshTokenStore()
        )

        await viewModel.signIn()

        let token = try await viewModel.playbackAccessToken()
        let browsingToken = try await viewModel.accessToken()
        let after401 = try await viewModel.refreshAccessTokenAfterUnauthorized()

        XCTAssertEqual(token, "live-token")
        XCTAssertEqual(browsingToken, "live-token")
        XCTAssertEqual(after401, "live-token")
        XCTAssertEqual(httpClient.requests.count, 2)
    }

    func testSignInRejectsInsufficientScopeGrant() async throws {
        let redirect = URL(string: "http://127.0.0.1:43824/callback")!
        let codeVerifier = try PKCE.makeCodeVerifier()
        let flow = ImmediateAuthorizationFlow(
            code: SpotifyAuthorizationCode(code: "code", codeVerifier: codeVerifier, redirectURI: redirect)
        )
        let httpClient = AuthCoverageHTTPClient(
            data: """
            {
              "access_token": "access-token",
              "token_type": "Bearer",
              "expires_in": 3600,
              "refresh_token": "refresh-token",
              "scope": "streaming"
            }
            """.data(using: .utf8)!,
            statusCode: 200
        )
        let viewModel = AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            authorizationFlow: flow,
            tokenClient: SpotifyTokenClient(httpClient: httpClient),
            refreshTokenStore: InMemoryRefreshTokenStore()
        )

        await viewModel.signIn()

        guard case let .failed(error) = viewModel.state else {
            return XCTFail("Expected failed state for missing browsing scopes")
        }
        XCTAssertTrue(error.message.contains("playlist") || error.message.contains("permissions"))
    }

    func testRefreshRestoresPersistedScopeWhenGrantOmitsScopeField() async throws {
        let store = InMemoryRefreshTokenStore()
        try store.saveRefreshToken("refresh-token")
        var settings = makeSettings(clientID: "client-id")
        settings.grantedScope = "playlist-read-private playlist-read-collaborative user-library-read streaming"
        let now = Date()
        let httpClient = AuthCoverageHTTPClient(
            data: """
            {
              "access_token": "new-access-token",
              "token_type": "Bearer",
              "expires_in": 1800
            }
            """.data(using: .utf8)!,
            statusCode: 200
        )
        let viewModel = AuthViewModel(
            settings: settings,
            tokenClient: SpotifyTokenClient(httpClient: httpClient, now: { now }),
            refreshTokenStore: store
        )

        await viewModel.restoreSessionIfAvailable()

        guard case let .signedIn(session) = viewModel.state else {
            return XCTFail("Expected signed-in after refresh, got \(viewModel.state)")
        }
        XCTAssertEqual(session.accessToken, "new-access-token")
        XCTAssertTrue(session.includesRequiredBrowsingScopes())
    }

    func testSignInSurfacesURLErrorMessages() async {
        let cases: [(URLError.Code, String)] = [
            (.notConnectedToInternet, "offline"),
            (.timedOut, "timed out"),
            (.cannotFindHost, "reach Spotify"),
            (.cancelled, "cancelled")
        ]
        for (code, marker) in cases {
            let viewModel = AuthViewModel(
                settings: makeSettings(clientID: "client-id"),
                authorizationFlow: FailingAuthorizationFlow(error: URLError(code)),
                tokenClient: SpotifyTokenClient(),
                refreshTokenStore: InMemoryRefreshTokenStore()
            )
            await viewModel.signIn()
            guard case let .failed(error) = viewModel.state else {
                return XCTFail("Expected failed for \(code)")
            }
            XCTAssertTrue(
                error.message.localizedCaseInsensitiveContains(marker),
                "Expected '\(marker)' in message for \(code), got: \(error.message)"
            )
        }
    }

    func testSignOutFailureSurfacesKeychainMessage() {
        let viewModel = AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            refreshTokenStore: FailingDeleteRefreshTokenStore()
        )

        viewModel.signOut()

        guard case let .failed(error) = viewModel.state else {
            return XCTFail("Expected failed sign-out")
        }
        XCTAssertTrue(error.message.contains("Disconnect"))
    }

    private func makeSettings(clientID: String) -> SpotifyAuthSettings {
        let suite = "SpotiglassTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(clientID, forKey: "spotify.clientID")
        return SpotifyAuthSettings(defaults: defaults)
    }
}

private struct ImmediateAuthorizationFlow: SpotifyAuthorizationFlowing {
    let code: SpotifyAuthorizationCode

    func requestAuthorizationCode(clientID: String, timeout: TimeInterval) async throws -> SpotifyAuthorizationCode {
        code
    }
}

private final class FailingAuthorizationFlow: SpotifyAuthorizationFlowing, @unchecked Sendable {
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func requestAuthorizationCode(clientID: String, timeout: TimeInterval) async throws -> SpotifyAuthorizationCode {
        throw error
    }
}

private final class AuthCoverageHTTPClient: HTTPClient {
    private let data: Data
    private let statusCode: Int

    init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (
            data,
            HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        )
    }
}

private final class FailingDeleteRefreshTokenStore: RefreshTokenStore {
    func loadRefreshToken() throws -> String? { "token" }
    func saveRefreshToken(_ refreshToken: String) throws {}
    func deleteRefreshToken() throws {
        throw KeychainRefreshTokenStoreError.invalidStoredData
    }
}

private final class InMemoryRefreshTokenStore: RefreshTokenStore {
    private var refreshToken: String?

    func loadRefreshToken() throws -> String? { refreshToken }
    func saveRefreshToken(_ refreshToken: String) throws { self.refreshToken = refreshToken }
    func deleteRefreshToken() throws { refreshToken = nil }
}
