import XCTest
@testable import Spotiglass

@MainActor
final class AuthViewModelCoverageTests: XCTestCase {
    func testClientIDDidSetPersistsToSettings() {
        let settings = SpotifyAuthSettings(defaults: makeEphemeralDefaults())
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

    func testSignOutInvalidatesDelayedRefreshCompletion() async throws {
        let store = InMemoryRefreshTokenStore()
        try store.saveRefreshToken("old-refresh-token")
        let httpClient = DelayedAuthHTTPClient(data: """
        {
          "access_token": "late-access-token",
          "token_type": "Bearer",
          "expires_in": 1800,
          "refresh_token": "late-refresh-token",
          "scope": "playlist-read-private playlist-read-collaborative user-library-read streaming"
        }
        """.data(using: .utf8)!)
        let viewModel = AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            tokenClient: SpotifyTokenClient(httpClient: httpClient),
            refreshTokenStore: store,
            signOutDataCleaner: {}
        )

        let refreshTask = Task { @MainActor in
            try await viewModel.refreshedPlaybackAccessToken()
        }
        await httpClient.waitUntilRequestStarted()

        viewModel.signOut()
        await httpClient.complete()
        _ = try? await refreshTask.value

        XCTAssertEqual(viewModel.state, .signedOut)
        XCTAssertNil(try store.loadRefreshToken())
    }

    func testReconnectInvalidatesDelayedRefreshCompletion() async throws {
        let store = InMemoryRefreshTokenStore()
        try store.saveRefreshToken("account-a-refresh-token")
        let redirect = URL(string: "http://127.0.0.1:43824/callback")!
        let codeVerifier = try PKCE.makeCodeVerifier()
        let flow = ImmediateAuthorizationFlow(
            code: SpotifyAuthorizationCode(code: "account-b-code", codeVerifier: codeVerifier, redirectURI: redirect)
        )
        let httpClient = ReconnectAuthHTTPClient(
            refreshData: """
            {
              "access_token": "account-a-late-access-token",
              "token_type": "Bearer",
              "expires_in": 1800,
              "refresh_token": "account-a-late-refresh-token",
              "scope": "playlist-read-private playlist-read-collaborative user-library-read streaming"
            }
            """.data(using: .utf8)!,
            signInData: """
            {
              "access_token": "account-b-access-token",
              "token_type": "Bearer",
              "expires_in": 3600,
              "refresh_token": "account-b-refresh-token",
              "scope": "playlist-read-private playlist-read-collaborative user-library-read streaming"
            }
            """.data(using: .utf8)!
        )
        let viewModel = AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            authorizationFlow: flow,
            tokenClient: SpotifyTokenClient(httpClient: httpClient),
            refreshTokenStore: store,
            signOutDataCleaner: {}
        )

        let refreshTask = Task { @MainActor in
            try await viewModel.refreshedPlaybackAccessToken()
        }
        await httpClient.waitUntilRefreshStarted()

        await viewModel.signIn()
        await httpClient.completeRefresh()
        _ = try? await refreshTask.value

        guard case let .signedIn(session) = viewModel.state else {
            return XCTFail("Expected account B to remain signed in, got \(viewModel.state)")
        }
        XCTAssertEqual(session.accessToken, "account-b-access-token")
        XCTAssertEqual(try store.loadRefreshToken(), "account-b-refresh-token")
    }

    func testDirectReconnectClearsPrivateLibraryButRetainsCatalogAndPins() async throws {
        let cache = try SpotifyLocalCache(rootDirectory: spotiglassTestsTemporaryDirectory())
        let oldPlaylist = PlaylistBrowsingTestFixtures.playlist(id: "account-a-playlist", name: "Account A")
        let oldPin = PinnedItem.playlist(oldPlaylist)
        try cache.savePlaylists([oldPlaylist])
        try cache.saveGETResponse(digest: "public-catalog", body: Data([7]), ttl: 300)
        try cache.savePinnedItems([oldPin], userID: "account-a")

        let redirect = URL(string: "http://127.0.0.1:43824/callback")!
        let codeVerifier = try PKCE.makeCodeVerifier()
        let flow = ImmediateAuthorizationFlow(
            code: SpotifyAuthorizationCode(code: "account-b-code", codeVerifier: codeVerifier, redirectURI: redirect)
        )
        let httpClient = AuthCoverageHTTPClient(
            data: """
            {
              "access_token": "account-b-access-token",
              "token_type": "Bearer",
              "expires_in": 3600,
              "refresh_token": "account-b-refresh-token",
              "scope": "playlist-read-private playlist-read-collaborative user-library-read streaming"
            }
            """.data(using: .utf8)!,
            statusCode: 200
        )
        let store = InMemoryRefreshTokenStore()
        try store.saveRefreshToken("account-a-refresh-token")
        let viewModel = AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            authorizationFlow: flow,
            tokenClient: SpotifyTokenClient(httpClient: httpClient),
            refreshTokenStore: store,
            signOutDataCleaner: { try? cache.clear() },
            initialState: .signedIn(AuthenticatedSession(
                accessToken: "account-a-access-token",
                tokenType: "Bearer",
                scope: "playlist-read-private playlist-read-collaborative user-library-read streaming",
                expiresAt: Date().addingTimeInterval(3_600)
            ))
        )

        await viewModel.signIn()

        XCTAssertNil(try cache.loadPlaylistsBundle())
        XCTAssertEqual(try cache.loadGETResponseRecord(digest: "public-catalog", allowExpired: false)?.data, Data([7]))
        XCTAssertEqual(try cache.loadPinnedItems(userID: "account-a"), [oldPin])
        XCTAssertEqual(try store.loadRefreshToken(), "account-b-refresh-token")
        guard case let .signedIn(session) = viewModel.state else {
            return XCTFail("Expected account B to be signed in, got \(viewModel.state)")
        }
        XCTAssertEqual(session.accessToken, "account-b-access-token")
    }

    func testSignOutPreservesPerAccountPinsForLaterRebind() throws {
        let cache = try SpotifyLocalCache(rootDirectory: spotiglassTestsTemporaryDirectory())
        let item = PinnedItem.playlist(PlaylistBrowsingTestFixtures.playlist(id: "account-a-playlist", name: "Account A"))
        try cache.savePinnedItems([item], userID: "account-a")
        let tokenStore = InMemoryRefreshTokenStore()
        try tokenStore.saveRefreshToken("account-a-refresh-token")
        let viewModel = AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            refreshTokenStore: tokenStore,
            signOutDataCleaner: { try? cache.clear() }
        )

        viewModel.signOut()

        XCTAssertNil(try tokenStore.loadRefreshToken())
        let pinnedStore = PinnedItemsStore(cache: cache)
        pinnedStore.bind(userID: "account-a")
        XCTAssertEqual(pinnedStore.items, [item])
        pinnedStore.bind(userID: "account-b")
        XCTAssertTrue(pinnedStore.items.isEmpty)
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
        let defaults = makeEphemeralDefaults()
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

private actor DelayedAuthHTTPClient: HTTPClient {
    private let responseData: Data
    private var requestStarted = false
    private var requestStartWaiter: CheckedContinuation<Void, Never>?
    private var responseContinuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var response: HTTPURLResponse?

    init(data: Data) {
        responseData = data
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestStarted = true
        requestStartWaiter?.resume()
        requestStartWaiter = nil
        response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return try await withCheckedThrowingContinuation { continuation in
            responseContinuation = continuation
        }
    }

    func waitUntilRequestStarted() async {
        if requestStarted { return }
        await withCheckedContinuation { continuation in
            requestStartWaiter = continuation
        }
    }

    func complete() {
        guard let responseContinuation, let response else { return }
        self.responseContinuation = nil
        self.response = nil
        responseContinuation.resume(returning: (responseData, response))
    }
}

private actor ReconnectAuthHTTPClient: HTTPClient {
    private let refreshData: Data
    private let signInData: Data
    private var refreshStarted = false
    private var refreshStartWaiter: CheckedContinuation<Void, Never>?
    private var refreshContinuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var refreshResponse: HTTPURLResponse?

    init(refreshData: Data, signInData: Data) {
        self.refreshData = refreshData
        self.signInData = signInData
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let isRefresh = String(data: request.httpBody ?? Data(), encoding: .utf8)?.contains("grant_type=refresh_token") == true
        let responseData = isRefresh ? refreshData : signInData
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        guard isRefresh else { return (responseData, response) }

        refreshStarted = true
        refreshStartWaiter?.resume()
        refreshStartWaiter = nil
        refreshResponse = response
        return try await withCheckedThrowingContinuation { continuation in
            refreshContinuation = continuation
        }
    }

    func waitUntilRefreshStarted() async {
        if refreshStarted { return }
        await withCheckedContinuation { continuation in
            refreshStartWaiter = continuation
        }
    }

    func completeRefresh() {
        guard let refreshContinuation, let refreshResponse else { return }
        self.refreshContinuation = nil
        self.refreshResponse = nil
        refreshContinuation.resume(returning: (refreshData, refreshResponse))
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
