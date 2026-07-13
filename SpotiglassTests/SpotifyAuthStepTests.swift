import Security
import XCTest
@testable import Spotiglass

final class SpotifyAuthStepTests: XCTestCase {
    func testPKCEVerifierUsesAllowedLengthAndCharacters() throws {
        let verifier = try PKCE.makeCodeVerifier()
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

        XCTAssertGreaterThanOrEqual(verifier.count, 43)
        XCTAssertLessThanOrEqual(verifier.count, 128)
        XCTAssertTrue(verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
    }

    func testPKCEChallengeMatchesRFC7636Vector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

        XCTAssertEqual(
            PKCE.makeCodeChallenge(for: verifier),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testPKCEChallengeIsBase64URLWithoutPadding() {
        let challenge = PKCE.makeCodeChallenge(for: "a-valid-code-verifier-value-with-enough-length-123")

        XCTAssertFalse(challenge.contains("+"))
        XCTAssertFalse(challenge.contains("/"))
        XCTAssertFalse(challenge.contains("="))
    }

    func testSpotifyAuthorizationURLUsesLoopbackRedirectAndScopes() throws {
        let redirectURI = URL(string: "http://127.0.0.1:49152/callback")!
        let configuration = try SpotifyAuthConfiguration(clientID: "client-123", redirectURI: redirectURI)
        let url = try configuration.authorizationURL(state: "state", codeChallenge: "challenge")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        XCTAssertEqual(components?.scheme, "https")
        XCTAssertEqual(components?.host, "accounts.spotify.com")
        XCTAssertEqual(items["client_id"], "client-123")
        XCTAssertEqual(items["redirect_uri"], "http://127.0.0.1:49152/callback")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertTrue(items["scope"]?.contains("playlist-read-private") == true)
        XCTAssertTrue(items["scope"]?.contains("user-library-read") == true)
        XCTAssertTrue(items["scope"]?.contains("streaming") == true)
    }

    func testAuthenticatedSessionValidatesRequiredBrowsingScopes() {
        let validSession = AuthenticatedSession(
            accessToken: "token",
            tokenType: "Bearer",
            scope: "playlist-read-private playlist-read-collaborative streaming",
            expiresAt: Date(timeIntervalSinceNow: 3_600)
        )
        let staleConsentSession = AuthenticatedSession(
            accessToken: "token",
            tokenType: "Bearer",
            scope: "streaming user-read-private",
            expiresAt: Date(timeIntervalSinceNow: 3_600)
        )

        XCTAssertTrue(validSession.includesRequiredBrowsingScopes())
        XCTAssertFalse(staleConsentSession.includesRequiredBrowsingScopes())
    }

    func testCallbackValidatorRequiresMatchingStateAndCode() throws {
        let url = URL(string: "http://127.0.0.1:49152/callback?code=abc123&state=expected")!

        let callback = try LoopbackOAuthCallbackValidator.validate(url: url, expectedState: "expected")

        XCTAssertEqual(callback.code, "abc123")
    }

    func testCallbackValidatorRejectsStateMismatch() {
        let url = URL(string: "http://127.0.0.1:49152/callback?code=abc123&state=wrong")!

        XCTAssertThrowsError(try LoopbackOAuthCallbackValidator.validate(url: url, expectedState: "expected")) { error in
            XCTAssertEqual(error as? LoopbackOAuthCallbackError, .stateMismatch)
        }
    }

    func testCallbackValidatorSurfacesOAuthError() {
        let url = URL(string: "http://127.0.0.1:49152/callback?error=access_denied&error_description=Denied")!

        XCTAssertThrowsError(try LoopbackOAuthCallbackValidator.validate(url: url, expectedState: "expected")) { error in
            XCTAssertEqual(error as? LoopbackOAuthCallbackError, .oauthError("access_denied", "Denied"))
        }
    }

    func testTokenExchangeParsesGrantAndDoesNotSendClientSecret() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let httpClient = MockHTTPClient(
            data: """
            {
              "access_token": "access-token",
              "token_type": "Bearer",
              "expires_in": 3600,
              "refresh_token": "refresh-token",
              "scope": "playlist-read-private streaming"
            }
            """.data(using: .utf8)!,
            statusCode: 200
        )
        let client = SpotifyTokenClient(httpClient: httpClient, now: { now })

        let grant = try await client.exchangeAuthorizationCode(
            clientID: "client-id",
            code: "code",
            codeVerifier: "verifier",
            redirectURI: URL(string: "http://127.0.0.1:49152/callback")!
        )

        XCTAssertEqual(grant.accessToken, "access-token")
        XCTAssertEqual(grant.refreshToken, "refresh-token")
        XCTAssertEqual(grant.expiresAt, Date(timeIntervalSince1970: 4_600))
        XCTAssertEqual(httpClient.lastBody?["grant_type"], "authorization_code")
        XCTAssertEqual(httpClient.lastBody?["client_id"], "client-id")
        XCTAssertNil(httpClient.lastBody?["client_secret"])
    }

    func testRefreshGrantUpdatesAuthSession() async throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let httpClient = MockHTTPClient(
            data: """
            {
              "access_token": "new-access-token",
              "token_type": "Bearer",
              "expires_in": 1800
            }
            """.data(using: .utf8)!,
            statusCode: 200
        )
        let client = SpotifyTokenClient(httpClient: httpClient, now: { now })
        let previous = AuthenticatedSession(
            accessToken: "old-access-token",
            tokenType: "Bearer",
            scope: "playlist-read-private",
            expiresAt: now
        )

        let grant = try await client.refreshAccessToken(clientID: "client-id", refreshToken: "refresh-token")
        let refreshed = previous.refreshed(with: grant)

        XCTAssertEqual(refreshed.accessToken, "new-access-token")
        XCTAssertEqual(refreshed.scope, "playlist-read-private")
        XCTAssertEqual(refreshed.expiresAt, Date(timeIntervalSince1970: 3_800))
        XCTAssertEqual(httpClient.lastBody?["grant_type"], "refresh_token")
        XCTAssertEqual(httpClient.lastBody?["refresh_token"], "refresh-token")
        XCTAssertNil(httpClient.lastBody?["client_secret"])
    }

    func testRefreshGrantRetriesTransientServerErrorsThenSucceeds() async throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let httpClient = SequencedTokenHTTPClient([
            .json(#"{"error":"temporarily_unavailable","error_description":"Try again"}"#, statusCode: 500),
            .json(#"{"error":"temporarily_unavailable","error_description":"Still retrying"}"#, statusCode: 502),
            .json("""
            {
              "access_token": "recovered-access-token",
              "token_type": "Bearer",
              "expires_in": 1800
            }
            """, statusCode: 200)
        ])
        let client = SpotifyTokenClient(httpClient: httpClient, now: { now }, random: { _ in 0 })

        let grant = try await client.refreshAccessToken(clientID: "client-id", refreshToken: "refresh-token")

        XCTAssertEqual(grant.accessToken, "recovered-access-token")
        XCTAssertEqual(httpClient.requestCount, 3, "Refresh should retry transient token endpoint failures with a bounded budget.")
    }

    func testRefreshGrantDoesNotRetryInvalidGrant() async {
        let httpClient = SequencedTokenHTTPClient([
            .json(#"{"error":"invalid_grant","error_description":"Refresh token revoked"}"#, statusCode: 400)
        ])
        let client = SpotifyTokenClient(httpClient: httpClient, random: { _ in 0 })

        do {
            _ = try await client.refreshAccessToken(clientID: "client-id", refreshToken: "refresh-token")
            XCTFail("Expected invalid_grant to fail without retry.")
        } catch let error as SpotifyTokenClientError {
            guard case let .httpError(status, description, oauthError, _) = error else {
                return XCTFail("Expected HTTP token error, got \(error)")
            }
            XCTAssertEqual(status, 400)
            XCTAssertEqual(description, "Refresh token revoked")
            XCTAssertEqual(oauthError, "invalid_grant")
            XCTAssertEqual(httpClient.requestCount, 1, "invalid_grant must fail immediately.")
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testInMemoryRefreshTokenStoreSignOutWipesToken() throws {
        let store = InMemoryRefreshTokenStore()
        try store.saveRefreshToken("refresh-token")

        try store.deleteRefreshToken()

        XCTAssertNil(try store.loadRefreshToken())
    }

    @MainActor
    func testSignOutClearsLocalCacheAndKeychain() async throws {
        let store = InMemoryRefreshTokenStore()
        try store.saveRefreshToken("refresh-token")
        let cleaner = SignOutCacheCleanerSpy()
        let viewModel = AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            tokenClient: SpotifyTokenClient(),
            refreshTokenStore: store,
            signOutDataCleaner: cleaner.invoke
        )

        viewModel.signOut()

        XCTAssertNil(try store.loadRefreshToken())
        XCTAssertEqual(cleaner.callCount, 1, "Sign-out must wipe cached library data alongside the Keychain.")
    }

    @MainActor
    func testRestoreSessionWipesKeychainOnInvalidGrant() async throws {
        let store = InMemoryRefreshTokenStore()
        try store.saveRefreshToken("revoked-refresh-token")
        let httpClient = MockHTTPClient(
            data: """
            { "error": "invalid_grant", "error_description": "Refresh token revoked" }
            """.data(using: .utf8)!,
            statusCode: 400
        )
        let cleaner = SignOutCacheCleanerSpy()
        let viewModel = AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            tokenClient: SpotifyTokenClient(httpClient: httpClient),
            refreshTokenStore: store,
            signOutDataCleaner: cleaner.invoke
        )

        await viewModel.restoreSessionIfAvailable()

        guard case let .failed(error) = viewModel.state else {
            return XCTFail("Expected failed auth state after invalid_grant")
        }
        XCTAssertTrue(error.message.contains("Refresh token revoked"))
        XCTAssertNil(try store.loadRefreshToken(), "Stale refresh tokens must be wiped after Spotify rejects them.")
        XCTAssertEqual(cleaner.callCount, 1, "Cache must be cleared when refresh fails permanently.")
    }

    @MainActor
    func testRestoreSessionPreservesKeychainOnTransientNetworkError() async throws {
        let store = InMemoryRefreshTokenStore()
        try store.saveRefreshToken("good-refresh-token")
        let httpClient = ThrowingHTTPClient(error: URLError(.notConnectedToInternet))
        let cleaner = SignOutCacheCleanerSpy()
        let viewModel = AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            tokenClient: SpotifyTokenClient(httpClient: httpClient),
            refreshTokenStore: store,
            signOutDataCleaner: cleaner.invoke
        )

        await viewModel.restoreSessionIfAvailable()

        guard case .failed = viewModel.state else {
            return XCTFail("Expected failed auth state on transient network error")
        }
        XCTAssertEqual(try store.loadRefreshToken(), "good-refresh-token", "Transient network failures must not wipe the refresh token.")
        XCTAssertEqual(cleaner.callCount, 0, "Cache must survive a transient refresh failure.")
    }

    @MainActor
    func testRefreshedPlaybackAccessTokenUsesSingleFlightForConcurrentWaiters() async throws {
        let store = InMemoryRefreshTokenStore()
        try store.saveRefreshToken("refresh-token")
        let now = Date(timeIntervalSince1970: 2_000)
        let httpClient = SequencedTokenHTTPClient([
            .json("""
            {
              "access_token": "shared-access-token",
              "token_type": "Bearer",
              "expires_in": 1800,
              "scope": "playlist-read-private playlist-read-collaborative user-library-read streaming"
            }
            """, statusCode: 200, delayNanoseconds: 150_000_000)
        ])
        let viewModel = AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            tokenClient: SpotifyTokenClient(httpClient: httpClient, now: { now }, random: { _ in 0 }),
            refreshTokenStore: store,
            signOutDataCleaner: {}
        )

        async let first = viewModel.refreshedPlaybackAccessToken()
        async let second = viewModel.refreshedPlaybackAccessToken()
        let (a, b) = try await (first, second)

        XCTAssertEqual(a, "shared-access-token")
        XCTAssertEqual(b, "shared-access-token")
        XCTAssertEqual(httpClient.requestCount, 1, "Concurrent refresh consumers should share one in-flight token call.")
    }

    @MainActor
    func testRefreshCooldownSuppressesImmediateRepeatAfterRetryExhaustion() async throws {
        let store = InMemoryRefreshTokenStore()
        try store.saveRefreshToken("refresh-token")
        let httpClient = SequencedTokenHTTPClient([
            .json(#"{"error":"temporarily_unavailable","error_description":"Try later"}"#, statusCode: 500),
            .json(#"{"error":"temporarily_unavailable","error_description":"Try later"}"#, statusCode: 500),
            .json(#"{"error":"temporarily_unavailable","error_description":"Try later"}"#, statusCode: 500)
        ])
        let viewModel = AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            tokenClient: SpotifyTokenClient(httpClient: httpClient, random: { _ in 0 }),
            refreshTokenStore: store,
            signOutDataCleaner: {}
        )

        do {
            _ = try await viewModel.refreshedPlaybackAccessToken()
            XCTFail("Expected first refresh to fail after bounded retries.")
        } catch {}

        do {
            _ = try await viewModel.refreshedPlaybackAccessToken()
            XCTFail("Expected cooldown to block immediate retry.")
        } catch {}

        XCTAssertEqual(httpClient.requestCount, 3, "Cooldown should fail fast without starting a second refresh attempt burst.")
    }

    func testKeychainRefreshTokenStoreErrorDescriptionsAreUserFacing() {
        let invalid = KeychainRefreshTokenStoreError.invalidStoredData
        XCTAssertTrue(((invalid as LocalizedError).errorDescription ?? "").contains("Disconnect"))

        let entitlement = KeychainRefreshTokenStoreError.unexpectedStatus(errSecMissingEntitlement)
        let entitlementDescription = (entitlement as LocalizedError).errorDescription ?? ""
        XCTAssertTrue(entitlementDescription.contains("macOS") || entitlementDescription.contains("Keychain"))
        XCTAssertFalse(entitlementDescription.localizedCaseInsensitiveContains("couldn't be completed"))

        let unknown = KeychainRefreshTokenStoreError.unexpectedStatus(OSStatus(-99_999))
        XCTAssertTrue(((unknown as LocalizedError).errorDescription ?? "").contains("-99999"))
    }

    func testLoopbackOAuthCallbackErrorLocalizedDescriptions() {
        XCTAssertTrue(((LoopbackOAuthCallbackError.timedOut as LocalizedError).errorDescription ?? "").contains("timed out"))
        XCTAssertEqual(
            (LoopbackOAuthCallbackError.oauthError("access_denied", "User declined") as LocalizedError).errorDescription,
            "User declined"
        )
    }

    @MainActor
    func testCancelSignInReturnsToSignedOutWithoutFailedBanner() async {
        let flow = HangUntilCancelledAuthorizationFlow()
        let viewModel = AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            authorizationFlow: flow,
            tokenClient: SpotifyTokenClient(),
            refreshTokenStore: InMemoryRefreshTokenStore(),
            signOutDataCleaner: {}
        )

        async let signInFinishes: Void = viewModel.signIn()
        await waitUntil { if case .signingIn = viewModel.state { return true }; return false }
        XCTAssertEqual(viewModel.state, .signingIn)

        viewModel.cancelSignIn()
        await signInFinishes

        XCTAssertEqual(viewModel.state, .signedOut)
    }

    @MainActor
    func testCancelSignInThenSecondConnectCanSucceed() async throws {
        let redirect = URL(string: "http://127.0.0.1:43824/callback")!
        let codeVerifier = try PKCE.makeCodeVerifier()
        let flow = TwoStepAuthorizationFlow {
            SpotifyAuthorizationCode(code: "auth-code", codeVerifier: codeVerifier, redirectURI: redirect)
        }
        let now = Date(timeIntervalSince1970: 1_000)
        let httpClient = MockHTTPClient(
            data: """
            {
              "access_token": "access-token",
              "token_type": "Bearer",
              "expires_in": 3600,
              "refresh_token": "refresh-token",
              "scope": "playlist-read-private playlist-read-collaborative user-library-read streaming"
            }
            """.data(using: .utf8)!,
            statusCode: 200
        )
        let tokenClient = SpotifyTokenClient(httpClient: httpClient, now: { now })
        let viewModel = AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            authorizationFlow: flow,
            tokenClient: tokenClient,
            refreshTokenStore: InMemoryRefreshTokenStore(),
            signOutDataCleaner: {}
        )

        async let firstAttempt: Void = viewModel.signIn()
        await waitUntil { if case .signingIn = viewModel.state { return true }; return false }
        viewModel.cancelSignIn()
        await firstAttempt
        XCTAssertEqual(viewModel.state, .signedOut)

        flow.advance()
        await viewModel.signIn()
        guard case let .signedIn(session) = viewModel.state else {
            return XCTFail("Expected signed-in state after second connect, got \(viewModel.state)")
        }
        XCTAssertEqual(session.accessToken, "access-token")
    }

    @MainActor
    func testSignInSingleFlightSuppressesConcurrentAttempts() async {
        let flow = CountingHangAuthorizationFlow()
        let viewModel = AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            authorizationFlow: flow,
            tokenClient: SpotifyTokenClient(),
            refreshTokenStore: InMemoryRefreshTokenStore(),
            signOutDataCleaner: {}
        )

        async let first: Void = viewModel.signIn()
        await waitUntil { flow.recordedRequestCount() == 1 }
        async let second: Void = viewModel.signIn()
        async let third: Void = viewModel.signIn()
        viewModel.cancelSignIn()
        await first
        await second
        await third

        XCTAssertEqual(flow.recordedRequestCount(), 1, "Concurrent sign-in attempts should reuse the active auth launch instead of restarting it.")
    }

    @MainActor
    func testSignInFailureCooldownBlocksImmediateRetryThenAllowsLaterRetry() async {
        let flow = FailingAuthorizationFlow(error: URLError(.timedOut))
        let viewModel = AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            authorizationFlow: flow,
            tokenClient: SpotifyTokenClient(),
            refreshTokenStore: InMemoryRefreshTokenStore(),
            signOutDataCleaner: {}
        )

        await viewModel.signIn()
        XCTAssertEqual(flow.recordedRequestCount(), 1)

        await viewModel.signIn()
        XCTAssertEqual(flow.recordedRequestCount(), 1, "Immediate retries should be ignored during cooldown.")

        try? await Task.sleep(nanoseconds: 2_200_000_000)
        await viewModel.signIn()
        XCTAssertEqual(flow.recordedRequestCount(), 2, "Retry should proceed after cooldown expires.")
    }

    private func makeSettings(clientID: String) -> SpotifyAuthSettings {
        let defaults = makeEphemeralDefaults()
        defaults.set(clientID, forKey: "spotify.clientID")
        return SpotifyAuthSettings(defaults: defaults)
    }
}

private func waitUntil(timeoutNanoseconds: UInt64 = 2_000_000_000, _ predicate: @escaping () -> Bool) async {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if predicate() { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("waitUntil timed out")
}

private struct HangUntilCancelledAuthorizationFlow: SpotifyAuthorizationFlowing {
    func requestAuthorizationCode(clientID: String, timeout: TimeInterval) async throws -> SpotifyAuthorizationCode {
        try await Task.sleep(for: .seconds(3_600))
        fatalError("unreachable")
    }
}

private final class TwoStepAuthorizationFlow: SpotifyAuthorizationFlowing, @unchecked Sendable {
    private let lock = NSLock()
    private var useSecondStep = false
    private let successCode: () throws -> SpotifyAuthorizationCode

    init(successCode: @escaping () throws -> SpotifyAuthorizationCode) {
        self.successCode = successCode
    }

    func advance() {
        lock.lock()
        useSecondStep = true
        lock.unlock()
    }

    func requestAuthorizationCode(clientID: String, timeout: TimeInterval) async throws -> SpotifyAuthorizationCode {
        lock.lock()
        let secondStep = useSecondStep
        lock.unlock()
        if secondStep {
            return try successCode()
        }
        try await Task.sleep(for: .seconds(3_600))
        fatalError("First authorization step should end by cancellation or timeout")
    }
}

private final class CountingHangAuthorizationFlow: SpotifyAuthorizationFlowing, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requestCount = 0

    func recordedRequestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCount
    }

    func requestAuthorizationCode(clientID: String, timeout: TimeInterval) async throws -> SpotifyAuthorizationCode {
        lock.lock()
        requestCount += 1
        lock.unlock()
        try await Task.sleep(for: .seconds(3_600))
        fatalError("unreachable")
    }
}

private final class FailingAuthorizationFlow: SpotifyAuthorizationFlowing, @unchecked Sendable {
    private let lock = NSLock()
    private let error: Error
    private(set) var requestCount = 0

    func recordedRequestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCount
    }

    init(error: Error) {
        self.error = error
    }

    func requestAuthorizationCode(clientID: String, timeout: TimeInterval) async throws -> SpotifyAuthorizationCode {
        lock.lock()
        requestCount += 1
        lock.unlock()
        throw error
    }
}

private final class SignOutCacheCleanerSpy: @unchecked Sendable {
    private(set) var callCount = 0

    func invoke() {
        callCount += 1
    }
}

private final class ThrowingHTTPClient: HTTPClient {
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw error
    }
}

private final class MockHTTPClient: HTTPClient {
    private let data: Data
    private let statusCode: Int
    private(set) var lastBody: [String: String]?

    init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let bodyData = request.httpBody,
           let body = String(data: bodyData, encoding: .utf8) {
            var components = URLComponents()
            components.percentEncodedQuery = body
            lastBody = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            })
        }

        return (
            data,
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }
}

private final class SequencedTokenHTTPClient: HTTPClient {
    struct Response {
        let data: Data
        let statusCode: Int
        let headers: [String: String]
        let delayNanoseconds: UInt64

        static func json(
            _ json: String,
            statusCode: Int = 200,
            headers: [String: String] = [:],
            delayNanoseconds: UInt64 = 0
        ) -> Response {
            Response(
                data: Data(json.utf8),
                statusCode: statusCode,
                headers: headers,
                delayNanoseconds: delayNanoseconds
            )
        }
    }

    private let lock = NSLock()
    private var responses: [Response]
    private(set) var requestCount = 0

    init(_ responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response: Response
        lock.lock()
        requestCount += 1
        guard !responses.isEmpty else {
            lock.unlock()
            throw URLError(.badServerResponse)
        }
        response = responses.removeFirst()
        lock.unlock()

        if response.delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: response.delayNanoseconds)
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

private final class InMemoryRefreshTokenStore: RefreshTokenStore {
    private var refreshToken: String?

    func loadRefreshToken() throws -> String? {
        refreshToken
    }

    func saveRefreshToken(_ refreshToken: String) throws {
        self.refreshToken = refreshToken
    }

    func deleteRefreshToken() throws {
        refreshToken = nil
    }
}
