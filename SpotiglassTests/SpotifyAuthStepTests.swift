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
            signOutDataCleaner: cleaner.invoke,
            artworkCacheClearer: {}
        )

        await viewModel.signOut()

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
            signOutDataCleaner: cleaner.invoke,
            artworkCacheClearer: {}
        )

        await viewModel.restoreSessionIfAvailable()

        guard case let .failed(error) = viewModel.state else {
            return XCTFail("Expected failed auth state after invalid_grant")
        }
        XCTAssertTrue(error.message.contains("Refresh token revoked"))
        XCTAssertNil(try store.loadRefreshToken(), "Stale refresh tokens must be wiped after Spotify rejects them.")
        XCTAssertEqual(cleaner.callCount, 1, "Cache must be cleared when refresh fails permanently.")
    }

    /// A user's log used to say nothing when a refresh failed and signed them out (#602, #593).
    @MainActor
    func testARejectedRefreshLeavesOneAuthLineSayingWhatHappened() async throws {
        let marker = "revoked-\(UUID().uuidString)"
        let store = InMemoryRefreshTokenStore()
        try store.saveRefreshToken("secret-refresh-token-602")
        let httpClient = MockHTTPClient(
            data: Data(#"{ "error": "invalid_grant", "error_description": "\#(marker)" }"#.utf8),
            statusCode: 400
        )
        let viewModel = AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            tokenClient: SpotifyTokenClient(httpClient: httpClient),
            refreshTokenStore: store,
            signOutDataCleaner: {},
            artworkCacheClearer: {}
        )

        await viewModel.restoreSessionIfAvailable()

        let lines = try SpotiglassLogReader.lines(containing: marker)
        XCTAssertEqual(lines.count, 1, "Expected one log line for the failed refresh, got: \(lines)")
        let line = try XCTUnwrap(lines.first)
        XCTAssertTrue(line.contains("[ERROR] [auth]"), line)
        for fact in ["refresh", "400", "invalid_grant", "signed out"] {
            XCTAssertTrue(line.contains(fact), "\(fact) is missing from: \(line)")
        }
        XCTAssertFalse(line.contains("secret-refresh-token-602"), "The log must never hold the token.")
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
            signOutDataCleaner: cleaner.invoke,
            artworkCacheClearer: {}
        )

        await viewModel.restoreSessionIfAvailable()

        guard case .paused = viewModel.state else {
            return XCTFail("Expected a paused sign-in on a transient network error, got \(viewModel.state)")
        }
        XCTAssertEqual(try store.loadRefreshToken(), "good-refresh-token", "Transient network failures must not wipe the refresh token.")
        XCTAssertEqual(cleaner.callCount, 0, "Cache must survive a transient refresh failure.")
    }

    /// #470 moved sign-in's network sentences into the shared mapping. A failure where the
    /// connection worked but the answer was unusable still reads as sign-in's "something went
    /// wrong", not as "check your network".
    @MainActor
    func testSignInNetworkFailuresSayWhatToCheck() async throws {
        let cases: [(URLError.Code, String)] = [
            (.badServerResponse, SpotiglassL10n.string("auth.error.generic")),
            (.cannotParseResponse, SpotiglassL10n.string("auth.error.generic")),
            (.cannotConnectToHost, SpotiglassL10n.string("auth.error.network")),
            (.notConnectedToInternet, SpotiglassL10n.string("auth.error.offline"))
        ]
        for (code, expected) in cases {
            // Since #593 a refresh that fails this way pauses instead; a sign-in still says it.
            let viewModel = AuthViewModel(
                settings: makeSettings(clientID: "client-id"),
                // URLSession's own text, which main showed as is.
                authorizationFlow: FailingAuthorizationFlow(
                    error: URLError(code, userInfo: [NSLocalizedDescriptionKey: "The server sent an answer that couldn’t be used."])
                ),
                tokenClient: SpotifyTokenClient(httpClient: ThrowingHTTPClient(error: URLError(.badURL))),
                refreshTokenStore: InMemoryRefreshTokenStore(),
                signOutDataCleaner: {},
                artworkCacheClearer: {}
            )

            await viewModel.signIn()

            guard case let .failed(error) = viewModel.state else {
                return XCTFail("\(code): expected a failed sign-in, got \(viewModel.state)")
            }
            XCTAssertEqual(error.message, expected, "\(code)")
        }
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
            """, statusCode: 200)
        ])
        let refreshHeld = MockCallHold()
        httpClient.hold = refreshHeld
        let viewModel = AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            tokenClient: SpotifyTokenClient(httpClient: httpClient, now: { now }, random: { _ in 0 }),
            refreshTokenStore: store,
            signOutDataCleaner: {},
            artworkCacheClearer: {}
        )

        let first = Task { try await viewModel.refreshedPlaybackAccessToken() }
        let didStartRefresh = await refreshHeld.entered.wait(timeout: .seconds(mustHappenTimeout))
        XCTAssertTrue(didStartRefresh, "the first caller should start the token call")
        // Runs on the main actor up to where it waits for the call already under way.
        let second = Task.immediate { try await viewModel.refreshedPlaybackAccessToken() }
        refreshHeld.release()
        let (a, b) = try await (first.value, second.value)

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
            signOutDataCleaner: {},
            artworkCacheClearer: {}
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
            signOutDataCleaner: {},
            artworkCacheClearer: {}
        )

        let signIn = await startSignIn(viewModel, untilLaunched: flow.launch.started)
        guard signIn.launched else { return XCTFail("signIn() returned without reaching the authorization flow") }
        XCTAssertEqual(viewModel.state, .signingIn)

        viewModel.cancelSignIn()
        guard flow.launch.wasCancelled else { return XCTFail("cancelSignIn() didn't cancel the browser launch") }
        await signIn.finished.value

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
            signOutDataCleaner: {},
            artworkCacheClearer: {}
        )

        let firstAttempt = await startSignIn(viewModel, untilLaunched: flow.firstStep.started)
        guard firstAttempt.launched else { return XCTFail("signIn() returned without reaching the authorization flow") }
        viewModel.cancelSignIn()
        guard flow.firstStep.wasCancelled else { return XCTFail("cancelSignIn() didn't cancel the browser launch") }
        await firstAttempt.finished.value
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
        let flow = CountingHangAuthorizationFlow(hangingLaunches: 1)
        let viewModel = AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            authorizationFlow: flow,
            tokenClient: SpotifyTokenClient(),
            refreshTokenStore: InMemoryRefreshTokenStore(),
            signOutDataCleaner: {},
            artworkCacheClearer: {}
        )

        let first = await startSignIn(viewModel, untilLaunched: flow.launch(1).started)
        guard first.launched else { return XCTFail("signIn() returned without reaching the authorization flow") }

        // Both attempts have run their single-flight check while the first launch is still waiting
        // for the browser, so they are concurrent with it by construction, not by how fast tasks
        // start. They may return at once or wait for the running sign-in; either way Cancel ends them.
        let second = await startExtraSignIn(viewModel)
        let third = await startExtraSignIn(viewModel)
        XCTAssertFalse(flow.launch(1).wasCancelled, "A concurrent sign-in attempt shouldn't cancel the running launch.")
        XCTAssertEqual(flow.recordedRequestCount(), 1, "Concurrent sign-in attempts should reuse the active auth launch instead of restarting it.")
        XCTAssertEqual(viewModel.state, .signingIn)

        viewModel.cancelSignIn()
        guard flow.launch(1).wasCancelled else { return XCTFail("cancelSignIn() didn't cancel the browser launch") }
        // A click right after Cancel, while the cancelled launch is still unwinding, is ignored too:
        // the first sign-in can't resume and clear its task until this test suspends.
        await viewModel.signIn()
        XCTAssertEqual(flow.recordedRequestCount(), 1, "A click right after Cancel shouldn't start a second launch while the first unwinds.")
        await first.finished.value
        await second.value
        await third.value

        XCTAssertEqual(flow.recordedRequestCount(), 1)
        XCTAssertEqual(viewModel.state, .signedOut)
    }

    /// The order a busy machine produced in #525: the extra attempts only got to run after the
    /// cancelled launch had finished. Each one is then a new sign-in and launches the browser
    /// again, and that launch has to end by itself (the real flow times out, a cancel stops it).
    @MainActor
    func testSignInAfterCancelledAttemptFinishedStartsAFreshLaunch() async {
        let flow = CountingHangAuthorizationFlow(hangingLaunches: 2)
        let viewModel = AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            authorizationFlow: flow,
            tokenClient: SpotifyTokenClient(),
            refreshTokenStore: InMemoryRefreshTokenStore(),
            signOutDataCleaner: {},
            artworkCacheClearer: {}
        )

        let first = await startSignIn(viewModel, untilLaunched: flow.launch(1).started)
        guard first.launched else { return XCTFail("signIn() returned without reaching the authorization flow") }
        viewModel.cancelSignIn()
        guard flow.launch(1).wasCancelled else { return XCTFail("cancelSignIn() didn't cancel the browser launch") }
        await first.finished.value
        XCTAssertEqual(viewModel.state, .signedOut)

        let late = await startSignIn(viewModel, untilLaunched: flow.launch(2).started)
        guard late.launched else {
            return XCTFail("A sign-in after the cancelled one finished should launch the browser again")
        }
        XCTAssertEqual(viewModel.state, .signingIn)
        // A third attempt while the fresh launch waits reuses it.
        let third = await startExtraSignIn(viewModel)
        XCTAssertFalse(flow.launch(2).wasCancelled, "A third attempt shouldn't cancel the fresh launch.")
        XCTAssertEqual(flow.recordedRequestCount(), 2)

        viewModel.cancelSignIn()
        guard flow.launch(2).wasCancelled else { return XCTFail("cancelSignIn() didn't cancel the browser launch") }
        await late.finished.value
        await third.value
        XCTAssertEqual(viewModel.state, .signedOut)
        XCTAssertEqual(flow.recordedRequestCount(), 2)
    }

    @MainActor
    func testSignInFailureCooldownBlocksImmediateRetryThenAllowsLaterRetry() async {
        let flow = FailingAuthorizationFlow(error: URLError(.timedOut))
        var now = Date(timeIntervalSince1970: 1_000)
        let viewModel = AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            authorizationFlow: flow,
            tokenClient: SpotifyTokenClient(),
            refreshTokenStore: InMemoryRefreshTokenStore(),
            signOutDataCleaner: {},
            artworkCacheClearer: {},
            now: { now }
        )

        await viewModel.signIn()
        XCTAssertEqual(flow.recordedRequestCount(), 1)

        await viewModel.signIn()
        XCTAssertEqual(flow.recordedRequestCount(), 1, "Immediate retries should be ignored during cooldown.")

        now = now.addingTimeInterval(2)
        await viewModel.signIn()
        XCTAssertEqual(flow.recordedRequestCount(), 2, "Retry should proceed after cooldown expires.")
    }

    /// Starts `signIn()` and waits until it reaches the authorization flow (`launched` fires) or
    /// returns without getting there, whichever comes first. Both are events, so a sign-in that
    /// wrongly never launches fails the test at once instead of waiting for the time limit.
    @MainActor
    private func startSignIn(
        _ viewModel: AuthViewModel,
        untilLaunched launched: AsyncSignal
    ) async -> (finished: Task<Void, Never>, launched: Bool) {
        let returned = AsyncSignal()
        let finished = Task { @MainActor in
            await viewModel.signIn()
            returned.signal()
        }
        let didLaunch = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await launched.wait(); return true }
            group.addTask { await returned.wait(); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        return (finished, didLaunch)
    }

    /// Starts another `signIn()` while one is running and returns once its single-flight check has
    /// run (the check runs in the same main-actor step as `entered`), without waiting for it to end.
    /// Whether it returns at once or waits for the running sign-in, the test can go on to Cancel.
    @MainActor
    private func startExtraSignIn(_ viewModel: AuthViewModel) async -> Task<Void, Never> {
        let entered = AsyncSignal()
        let task = Task { @MainActor in
            entered.signal()
            await viewModel.signIn()
        }
        await entered.wait()
        return task
    }

    private func makeSettings(clientID: String) -> SpotifyAuthSettings {
        let defaults = makeEphemeralDefaults()
        defaults.set(clientID, forKey: "spotify.clientID")
        return SpotifyAuthSettings(defaults: defaults)
    }
}

/// A browser sign-in nobody finishes: it waits until its task is cancelled. `started` fires once the
/// cancel handler is in place, and `wasCancelled` turns true inside that handler, which
/// `Task.cancel()` runs during the call. So right after `cancelSignIn()` a test can check that the
/// cancel arrived, instead of finding out by waiting for a launch that never ends.
private final class HangingLaunch: @unchecked Sendable {
    let started = AsyncSignal()
    private let lock = NSLock()
    private var cancelled = false

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func run() async throws -> Never {
        let cancellationSignal = AsyncSignal()
        try await withTaskCancellationHandler(operation: {
            started.signal()
            await cancellationSignal.wait()
            try Task.checkCancellation()
        }, onCancel: {
            lock.lock()
            cancelled = true
            lock.unlock()
            cancellationSignal.signal()
        })
        fatalError("A hanging launch ends only by cancellation")
    }
}

private struct HangUntilCancelledAuthorizationFlow: SpotifyAuthorizationFlowing {
    let launch = HangingLaunch()

    func requestAuthorizationCode(clientID: String, timeout: TimeInterval) async throws -> SpotifyAuthorizationCode {
        try await launch.run()
    }
}

private final class TwoStepAuthorizationFlow: SpotifyAuthorizationFlowing, @unchecked Sendable {
    private let lock = NSLock()
    private var useSecondStep = false
    let firstStep = HangingLaunch()
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
        try await firstStep.run()
    }
}

private final class CountingHangAuthorizationFlow: SpotifyAuthorizationFlowing, @unchecked Sendable {
    private let lock = NSLock()
    private let hangingLaunches: Int
    private var requestCount = 0
    private var launches: [HangingLaunch] = []

    /// The first `hangingLaunches` launches wait until cancelled, like a browser sign-in nobody finishes.
    /// Any launch after that ends at once, so if single-flight breaks, the extra `signIn()` returns
    /// and the count assertion fails, instead of the test waiting on a launch nothing cancels.
    init(hangingLaunches: Int) {
        self.hangingLaunches = hangingLaunches
    }

    func recordedRequestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCount
    }

    /// The `count`-th launch. Its `started` fires once it reached the flow, however late its task starts.
    func launch(_ count: Int) -> HangingLaunch {
        lock.lock()
        defer { lock.unlock() }
        while launches.count < count { launches.append(HangingLaunch()) }
        return launches[count - 1]
    }

    func requestAuthorizationCode(clientID: String, timeout: TimeInterval) async throws -> SpotifyAuthorizationCode {
        lock.lock()
        requestCount += 1
        let count = requestCount
        lock.unlock()
        let current = launch(count)
        guard count <= hangingLaunches else {
            current.started.signal()
            throw CancellationError()
        }
        try await current.run()
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

        static func json(
            _ json: String,
            statusCode: Int = 200,
            headers: [String: String] = [:]
        ) -> Response {
            Response(
                data: Data(json.utf8),
                statusCode: statusCode,
                headers: headers
            )
        }
    }

    private let lock = NSLock()
    private var responses: [Response]
    private(set) var requestCount = 0
    /// Holds the first request until the test releases it; a second request releases it too.
    var hold: MockCallHold?

    init(_ responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requestCount += 1 }
        await hold?.pass()
        let response: Response
        lock.lock()
        guard !responses.isEmpty else {
            lock.unlock()
            throw URLError(.badServerResponse)
        }
        response = responses.removeFirst()
        lock.unlock()

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

/// A Keychain that holds a token but refuses to save a new one.
private final class SaveRefusingRefreshTokenStore: RefreshTokenStore {
    private let refreshToken: String
    init(refreshToken: String) { self.refreshToken = refreshToken }
    func loadRefreshToken() throws -> String? { refreshToken }
    func saveRefreshToken(_ refreshToken: String) throws { throw KeychainRefreshTokenStoreError.unexpectedStatus(-25_308) }
    func deleteRefreshToken() throws { throw KeychainRefreshTokenStoreError.unexpectedStatus(-25_308) }
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

// MARK: - A temporary problem never signs me out (#593)

/// Each test replays one way a temporary problem used to end in being signed out, and fails on
/// the code before #593. Time goes through an injected clock and sleeper, and the network coming
/// back (or the Mac waking) is an explicit signal.
extension SpotifyAuthStepTests {
    private static let browsingScope = "playlist-read-private playlist-read-collaborative user-library-read streaming"

    private static func grantJSON(_ accessToken: String, refreshToken: String? = nil) -> String {
        let refresh = refreshToken.map { #", "refresh_token": "\#($0)""# } ?? ""
        return """
        { "access_token": "\(accessToken)", "token_type": "Bearer", "expires_in": 3600, "scope": "\(browsingScope)"\(refresh) }
        """
    }

    /// Wax started at login before Wi-Fi joined. The sign-in must stay (library on screen, token
    /// kept) and come back by itself when the network does, without Connect.
    @MainActor
    func testOfflineLaunchKeepsTheLibraryAndSignsBackInWhenTheNetworkReturns() async throws {
        let store = InMemoryRefreshTokenStore()
        try store.saveRefreshToken("good-refresh-token")
        let http = ScriptedTokenHTTPClient()
        http.enqueue(.failure(URLError(.notConnectedToInternet)), count: 3)
        let cleaner = SignOutCacheCleanerSpy()
        let (signals, network) = AsyncStream<Void>.makeStream()
        var settings = makeSettings(clientID: "client-id")
        settings.grantedScope = Self.browsingScope
        let viewModel = AuthViewModel(
            settings: settings,
            tokenClient: SpotifyTokenClient(httpClient: http, random: { _ in 0 }, sleep: { _ in }),
            refreshTokenStore: store,
            signOutDataCleaner: cleaner.invoke,
            artworkCacheClearer: {},
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) },
            recoverySignals: signals
        )

        await viewModel.restoreSessionIfAvailable()

        guard case let .paused(pause) = viewModel.state else {
            return XCTFail("Offline at launch must keep the sign-in, got \(viewModel.state)")
        }
        XCTAssertEqual(pause.reason, .offline)
        XCTAssertTrue(viewModel.state.hasSpotifySession, "The library stays on screen; Connect is not the way out of being offline.")
        XCTAssertEqual(viewModel.state.message, SpotiglassL10n.string("app.connection.paused.offline"))
        XCTAssertEqual(try store.loadRefreshToken(), "good-refresh-token")
        XCTAssertEqual(cleaner.callCount, 0)
        let scopes = await viewModel.grantedScopes()
        XCTAssertTrue(scopes.contains("streaming"), "Features gated on scopes stay available while paused.")

        http.enqueue(.json(Self.grantJSON("back-online")))
        network.yield()
        let session = await signedInSession(of: viewModel)

        XCTAssertEqual(session.accessToken, "back-online")
        XCTAssertEqual(http.requestCount, 4)
    }

    /// A refresh that fails mid-session because the network dropped tells the request so in calm
    /// words (not "session expired"), and the next request after the cooldown tries again.
    @MainActor
    func testNetworkBlipMidSessionGivesTheRealReasonAndTheNextRequestRetries() async throws {
        let store = InMemoryRefreshTokenStore()
        try store.saveRefreshToken("good-refresh-token")
        let http = ScriptedTokenHTTPClient()
        http.enqueue(.failure(URLError(.networkConnectionLost)), count: 3)
        let clock = TestClock(Date(timeIntervalSince1970: 50_000))
        let expired = AuthenticatedSession(accessToken: "old", tokenType: "Bearer", scope: Self.browsingScope, expiresAt: clock.now)
        let viewModel = AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            tokenClient: SpotifyTokenClient(httpClient: http, now: { clock.now }, random: { _ in 0 }, sleep: { _ in }),
            refreshTokenStore: store,
            signOutDataCleaner: {},
            artworkCacheClearer: {},
            initialState: .signedIn(expired),
            now: { clock.now },
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) },
            recoverySignals: AsyncStream { _ in }
        )

        do {
            _ = try await viewModel.accessToken()
            XCTFail("Expected the refresh to fail while offline")
        } catch let error as SpotifySignInPausedError {
            XCTAssertEqual(error.pause.reason, .offline)
            XCTAssertEqual(MusicServiceErrorText.userMessage(for: error, service: .spotify), SpotiglassL10n.string("app.connection.paused.offline"))
        } catch {
            XCTFail("A network error must not read as an expired session, got \(error)")
        }
        XCTAssertEqual(try store.loadRefreshToken(), "good-refresh-token")
        guard case let .paused(pause) = viewModel.state else { return XCTFail("Expected paused, got \(viewModel.state)") }
        XCTAssertEqual(pause.session, expired)

        clock.now += AuthViewModel.temporaryFailureCooldown + 1
        http.enqueue(.json(Self.grantJSON("next-request")))
        let token = try await viewModel.accessToken()

        XCTAssertEqual(token, "next-request")
        XCTAssertEqual(viewModel.state, .signedIn(AuthenticatedSession(
            accessToken: "next-request", tokenType: "Bearer", scope: Self.browsingScope, expiresAt: clock.now.addingTimeInterval(3_600)
        )))
    }

    /// The issue's own replay: /api/token answers 429 three times. The token and the library caches
    /// survive, and the sign-in waits as a visible cooldown instead of being called dead.
    @MainActor
    func testRateLimitedRefreshKeepsTheTokenAndCachesAndBecomesACooldown() async throws {
        let store = InMemoryRefreshTokenStore()
        try store.saveRefreshToken("good-refresh-token")
        let http = ScriptedTokenHTTPClient()
        http.enqueue(.json(#"{"error":"rate_limited"}"#, statusCode: 429), count: 3)
        let cleaner = SignOutCacheCleanerSpy()
        var artworkCleared = false
        let clock = TestClock(Date(timeIntervalSince1970: 60_000))
        let viewModel = AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            tokenClient: SpotifyTokenClient(httpClient: http, now: { clock.now }, random: { _ in 0 }, sleep: { _ in }),
            refreshTokenStore: store,
            signOutDataCleaner: cleaner.invoke,
            artworkCacheClearer: { artworkCleared = true },
            now: { clock.now },
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) },
            recoverySignals: AsyncStream { _ in }
        )

        await viewModel.restoreSessionIfAvailable()

        XCTAssertEqual(try store.loadRefreshToken(), "good-refresh-token")
        XCTAssertEqual(cleaner.callCount, 0)
        XCTAssertFalse(artworkCleared)
        guard case let .paused(pause) = viewModel.state else { return XCTFail("Expected paused, got \(viewModel.state)") }
        XCTAssertEqual(pause.reason, .busy)
        XCTAssertEqual(pause.retryAt, clock.now.addingTimeInterval(AuthViewModel.temporaryFailureCooldown))
    }

    /// `Retry-After: 3600` used to be slept inside the refresh (twice) with every request waiting
    /// on it, and then the token was deleted. Now the refresh returns at once, the wait shows as a
    /// cooldown with its time, requests during it don't hit Spotify, and the sign-in tries again by
    /// itself when it ends.
    @MainActor
    func testLongRetryAfterIsACooldownThatRetriesByItselfWhenItEnds() async throws {
        let store = InMemoryRefreshTokenStore()
        try store.saveRefreshToken("good-refresh-token")
        let http = ScriptedTokenHTTPClient()
        http.enqueue(.json(#"{"error":"rate_limited"}"#, statusCode: 429, headers: ["Retry-After": "3600"]))
        let tokenClientSleeps = RetryDelayLog()
        let clock = TestClock(Date(timeIntervalSince1970: 70_000))
        let sleeper = ManualSleeper()
        let (signals, network) = AsyncStream<Void>.makeStream()
        let viewModel = AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            tokenClient: SpotifyTokenClient(
                httpClient: http, now: { clock.now }, random: { _ in 0 }, sleep: { tokenClientSleeps.append($0) }
            ),
            refreshTokenStore: store,
            signOutDataCleaner: {},
            artworkCacheClearer: {},
            now: { clock.now },
            sleep: { try await sleeper.sleep($0) },
            recoverySignals: signals
        )

        await viewModel.restoreSessionIfAvailable()

        XCTAssertEqual(http.requestCount, 1, "A long Retry-After is not waited out inside the refresh.")
        XCTAssertEqual(tokenClientSleeps.values, [])
        guard case let .paused(pause) = viewModel.state else { return XCTFail("Expected paused, got \(viewModel.state)") }
        let retryAt = try XCTUnwrap(pause.retryAt)
        XCTAssertEqual(retryAt, clock.now.addingTimeInterval(3_600))
        XCTAssertTrue(viewModel.state.message.contains(
            retryAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(SpotiglassL10n.locale))
        ))
        XCTAssertEqual(try store.loadRefreshToken(), "good-refresh-token")

        do {
            _ = try await viewModel.accessToken()
            XCTFail("Expected the cooldown to answer the request")
        } catch let error as SpotifySignInPausedError {
            XCTAssertEqual(error.pause.reason, .busy)
        }
        XCTAssertEqual(http.requestCount, 1, "Requests during the cooldown don't ask Spotify again.")

        let delay = await sleeper.nextSleep()
        XCTAssertEqual(delay, 3_600)
        clock.now += 3_600
        http.enqueue(.json(Self.grantJSON("after-cooldown")))
        await sleeper.wake()
        let session = await signedInSession(of: viewModel)
        XCTAssertEqual(session.accessToken, "after-cooldown")
        XCTAssertEqual(http.requestCount, 2)
        network.finish()
    }

    /// Spotify's verdict on the grant is the only thing that deletes the sign-in.
    func testOnlyADeadGrantCountsAsSignedOut() {
        func http(_ status: Int, _ oauth: String?) -> Error {
            SpotifyTokenClientError.httpError(status, nil, oauth, nil)
        }
        XCTAssertEqual(AuthViewModel.refreshFailureKind(http(400, "invalid_grant")), .deadGrant)
        XCTAssertEqual(AuthViewModel.refreshFailureKind(http(400, "invalid_client")), .deadGrant)
        XCTAssertEqual(AuthViewModel.refreshFailureKind(http(401, "invalid_client")), .deadGrant)
        XCTAssertEqual(AuthViewModel.refreshFailureKind(http(400, "unauthorized_client")), .deadGrant)
        XCTAssertEqual(AuthViewModel.refreshFailureKind(http(429, nil)), .temporary(.busy, retryAfter: nil))
        XCTAssertEqual(
            AuthViewModel.refreshFailureKind(SpotifyTokenClientError.httpError(429, nil, nil, 120)),
            .temporary(.busy, retryAfter: 120)
        )
        XCTAssertEqual(AuthViewModel.refreshFailureKind(http(503, nil)), .temporary(.busy, retryAfter: nil))
        XCTAssertEqual(AuthViewModel.refreshFailureKind(URLError(.notConnectedToInternet)), .temporary(.offline, retryAfter: nil))
        XCTAssertEqual(AuthViewModel.refreshFailureKind(URLError(.timedOut)), .temporary(.unreachable, retryAfter: nil))
        XCTAssertEqual(AuthViewModel.refreshFailureKind(http(400, "invalid_request")), .other)
    }

    /// The issue's other replay: a signed-in Reconnect whose browser step can't bind its port
    /// keeps the old sign-in, its token and its library.
    @MainActor
    func testFailedReconnectKeepsTheWorkingSignIn() async throws {
        let store = InMemoryRefreshTokenStore()
        try store.saveRefreshToken("good-refresh-token")
        let cleaner = SignOutCacheCleanerSpy()
        let session = AuthenticatedSession(
            accessToken: "working", tokenType: "Bearer", scope: Self.browsingScope, expiresAt: Date().addingTimeInterval(3_600)
        )
        let viewModel = AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            authorizationFlow: FailingAuthorizationFlow(error: LoopbackOAuthCallbackError.socketSetupFailed("bind")),
            tokenClient: SpotifyTokenClient(httpClient: ScriptedTokenHTTPClient()),
            refreshTokenStore: store,
            signOutDataCleaner: cleaner.invoke,
            artworkCacheClearer: {},
            initialState: .signedIn(session),
            recoverySignals: AsyncStream { _ in }
        )

        await viewModel.signIn()

        XCTAssertEqual(try store.loadRefreshToken(), "good-refresh-token")
        XCTAssertEqual(cleaner.callCount, 0)
        XCTAssertEqual(viewModel.state, .signedIn(session))
        XCTAssertNotNil(viewModel.reconnectFailure, "Settings says the reconnect didn't finish instead of nothing happening.")
        let token = try await viewModel.accessToken()
        XCTAssertEqual(token, "working")
    }

    /// A reconnect whose new grant can't browse the library (scopes missing) keeps the sign-in
    /// from before, its token and its caches, and says so in Settings.
    @MainActor
    func testReconnectWithoutBrowsingScopesKeepsTheOldSignIn() async throws {
        let store = InMemoryRefreshTokenStore()
        try store.saveRefreshToken("good-refresh-token")
        let cleaner = SignOutCacheCleanerSpy()
        let http = ScriptedTokenHTTPClient()
        http.enqueue(.json("""
        { "access_token": "narrow", "token_type": "Bearer", "expires_in": 3600, "scope": "user-read-email", "refresh_token": "narrow-token" }
        """))
        let viewModel = makeReconnectingViewModel(store: store, http: http, cleaner: cleaner)
        guard case let .signedIn(session) = viewModel.state else { return XCTFail("Expected signed in, got \(viewModel.state)") }

        await viewModel.signIn()

        XCTAssertEqual(viewModel.state, .signedIn(session))
        XCTAssertEqual(try store.loadRefreshToken(), "good-refresh-token")
        XCTAssertEqual(cleaner.callCount, 0)
        XCTAssertNotNil(viewModel.reconnectFailure)
    }

    /// Cancel pressed while a saved new grant clears the old caches: the sign-in finishes instead
    /// of leaving the new token saved and nothing signed in.
    @MainActor
    func testCancelWhileTheNewSignInIsBeingCommittedLetsItFinish() async throws {
        let store = InMemoryRefreshTokenStore()
        try store.saveRefreshToken("good-refresh-token")
        let http = ScriptedTokenHTTPClient()
        http.enqueue(.json(Self.grantJSON("new-account", refreshToken: "new-account-token")))
        let cleanupStarted = AsyncSignal()
        let finishCleanup = AsyncSignal()
        let viewModel = makeReconnectingViewModel(store: store, http: http, cleaner: SignOutCacheCleanerSpy()) {
            cleanupStarted.signal()
            await finishCleanup.wait()
        }

        let reconnect = Task { @MainActor in await viewModel.signIn() }
        await cleanupStarted.wait()
        viewModel.cancelSignIn()
        finishCleanup.signal()
        await reconnect.value

        guard case let .signedIn(session) = viewModel.state else { return XCTFail("Expected signed in, got \(viewModel.state)") }
        XCTAssertEqual(session.accessToken, "new-account")
        XCTAssertEqual(try store.loadRefreshToken(), "new-account-token")
    }

    /// A refresh failed for a reason that isn't temporary, so Connect is on screen with the old
    /// session still in memory. If that sign-in fails too, the screen says why; it doesn't claim
    /// I'm still signed in.
    @MainActor
    func testFailedSignInAfterAFailedRefreshShowsItsReason() async throws {
        let store = InMemoryRefreshTokenStore()
        try store.saveRefreshToken("good-refresh-token")
        let http = ScriptedTokenHTTPClient()
        http.enqueue(.json(#"{"error":"invalid_request"}"#, statusCode: 400))
        let expired = AuthenticatedSession(
            accessToken: "old", tokenType: "Bearer", scope: Self.browsingScope, expiresAt: Date(timeIntervalSince1970: 1_000)
        )
        let viewModel = AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            authorizationFlow: FailingAuthorizationFlow(error: LoopbackOAuthCallbackError.socketSetupFailed("bind")),
            tokenClient: SpotifyTokenClient(httpClient: http, random: { _ in 0 }, sleep: { _ in }),
            refreshTokenStore: store,
            signOutDataCleaner: {},
            artworkCacheClearer: {},
            initialState: .signedIn(expired),
            recoverySignals: AsyncStream { _ in }
        )
        _ = try? await viewModel.accessToken()
        guard case .failed = viewModel.state else { return XCTFail("Expected failed, got \(viewModel.state)") }

        await viewModel.signIn()

        guard case .failed = viewModel.state else { return XCTFail("Expected the new failure on screen, got \(viewModel.state)") }
        XCTAssertNil(viewModel.reconnectFailure, "Nothing was signed in before, so Settings mustn't say it still is.")
        XCTAssertEqual(try store.loadRefreshToken(), "good-refresh-token")
    }

    /// Reconnect pressed while the saved sign-in is still being refreshed at launch, and the
    /// browser step fails: the saved sign-in is refreshed again instead of an error replacing it.
    @MainActor
    func testFailedReconnectDuringTheLaunchRefreshTriesTheSavedSignInAgain() async throws {
        let store = InMemoryRefreshTokenStore()
        try store.saveRefreshToken("good-refresh-token")
        let http = ScriptedTokenHTTPClient()
        http.enqueue(.json(Self.grantJSON("restored")))
        let viewModel = AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            authorizationFlow: FailingAuthorizationFlow(error: LoopbackOAuthCallbackError.socketSetupFailed("bind")),
            tokenClient: SpotifyTokenClient(httpClient: http, random: { _ in 0 }, sleep: { _ in }),
            refreshTokenStore: store,
            signOutDataCleaner: {},
            artworkCacheClearer: {},
            initialState: .refreshing(nil),
            recoverySignals: AsyncStream { _ in }
        )

        await viewModel.signIn()
        let session = await signedInSession(of: viewModel)

        XCTAssertEqual(session.accessToken, "restored")
        XCTAssertNil(viewModel.reconnectFailure)
    }

    @MainActor
    private func makeReconnectingViewModel(
        store: InMemoryRefreshTokenStore,
        http: ScriptedTokenHTTPClient,
        cleaner: SignOutCacheCleanerSpy,
        artworkCacheClearer: @escaping () async -> Void = {}
    ) -> AuthViewModel {
        let redirect = URL(string: "http://127.0.0.1:43824/callback")!
        let codeVerifier = (try? PKCE.makeCodeVerifier()) ?? "verifier"
        let flow = TwoStepAuthorizationFlow {
            SpotifyAuthorizationCode(code: "auth-code", codeVerifier: codeVerifier, redirectURI: redirect)
        }
        flow.advance()
        let session = AuthenticatedSession(
            accessToken: "working", tokenType: "Bearer", scope: Self.browsingScope, expiresAt: Date().addingTimeInterval(3_600)
        )
        return AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            authorizationFlow: flow,
            tokenClient: SpotifyTokenClient(httpClient: http, random: { _ in 0 }, sleep: { _ in }),
            refreshTokenStore: store,
            signOutDataCleaner: cleaner.invoke,
            artworkCacheClearer: artworkCacheClearer,
            initialState: .signedIn(session),
            recoverySignals: AsyncStream { _ in }
        )
    }

    /// The new grant arrives but the Keychain won't save it: the old sign-in and its library caches
    /// must still be there, since nothing replaced them.
    @MainActor
    func testReconnectWhoseTokenCantBeSavedKeepsTheOldSignInAndCaches() async throws {
        let store = SaveRefusingRefreshTokenStore(refreshToken: "good-refresh-token")
        let cleaner = SignOutCacheCleanerSpy()
        let http = ScriptedTokenHTTPClient()
        http.enqueue(.json(Self.grantJSON("new-account", refreshToken: "new-account-token")))
        let redirect = URL(string: "http://127.0.0.1:43824/callback")!
        let codeVerifier = try PKCE.makeCodeVerifier()
        let flow = TwoStepAuthorizationFlow {
            SpotifyAuthorizationCode(code: "auth-code", codeVerifier: codeVerifier, redirectURI: redirect)
        }
        flow.advance()
        let session = AuthenticatedSession(
            accessToken: "working", tokenType: "Bearer", scope: Self.browsingScope, expiresAt: Date().addingTimeInterval(3_600)
        )
        let viewModel = AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            authorizationFlow: flow,
            tokenClient: SpotifyTokenClient(httpClient: http, random: { _ in 0 }, sleep: { _ in }),
            refreshTokenStore: store,
            signOutDataCleaner: cleaner.invoke,
            artworkCacheClearer: {},
            initialState: .signedIn(session),
            recoverySignals: AsyncStream { _ in }
        )

        await viewModel.signIn()

        XCTAssertEqual(http.requestCount, 1, "The new grant did arrive.")
        XCTAssertEqual(try store.loadRefreshToken(), "good-refresh-token")
        XCTAssertEqual(cleaner.callCount, 0, "The old library caches stay until a new sign-in is saved.")
        XCTAssertEqual(viewModel.state, .signedIn(session))
        XCTAssertNotNil(viewModel.reconnectFailure)
    }

    /// Settings › Reconnect, then Cancel: still signed in, library still there.
    @MainActor
    func testCancelledReconnectKeepsTheWorkingSignIn() async throws {
        let store = InMemoryRefreshTokenStore()
        try store.saveRefreshToken("good-refresh-token")
        let cleaner = SignOutCacheCleanerSpy()
        let flow = HangUntilCancelledAuthorizationFlow()
        let session = AuthenticatedSession(
            accessToken: "working", tokenType: "Bearer", scope: Self.browsingScope, expiresAt: Date().addingTimeInterval(3_600)
        )
        let viewModel = AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            authorizationFlow: flow,
            tokenClient: SpotifyTokenClient(httpClient: ScriptedTokenHTTPClient()),
            refreshTokenStore: store,
            signOutDataCleaner: cleaner.invoke,
            artworkCacheClearer: {},
            initialState: .signedIn(session),
            recoverySignals: AsyncStream { _ in }
        )

        let reconnect = await startSignIn(viewModel, untilLaunched: flow.launch.started)
        guard reconnect.launched else { return XCTFail("signIn() returned without reaching the authorization flow") }
        viewModel.cancelSignIn()
        await reconnect.finished.value

        XCTAssertEqual(try store.loadRefreshToken(), "good-refresh-token")
        XCTAssertEqual(cleaner.callCount, 0)
        XCTAssertEqual(viewModel.state, .signedIn(session))
    }

    /// A refresh error that is neither a dead grant nor temporary keeps the token and the library
    /// caches and shows Connect. Signing in from there may be another account, so the caches of the
    /// sign-in before must go once the new grant arrives (#233, #234).
    @MainActor
    func testConnectAfterAFailedRefreshClearsTheEarlierSignInsCaches() async throws {
        let store = InMemoryRefreshTokenStore()
        try store.saveRefreshToken("first-account-token")
        let http = ScriptedTokenHTTPClient()
        http.enqueue(.json(#"{"error":"invalid_request"}"#, statusCode: 400))
        let cleaner = SignOutCacheCleanerSpy()
        let redirect = URL(string: "http://127.0.0.1:43824/callback")!
        let codeVerifier = try PKCE.makeCodeVerifier()
        let flow = TwoStepAuthorizationFlow {
            SpotifyAuthorizationCode(code: "auth-code", codeVerifier: codeVerifier, redirectURI: redirect)
        }
        flow.advance()
        let viewModel = AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            authorizationFlow: flow,
            tokenClient: SpotifyTokenClient(httpClient: http, random: { _ in 0 }, sleep: { _ in }),
            refreshTokenStore: store,
            signOutDataCleaner: cleaner.invoke,
            artworkCacheClearer: {},
            recoverySignals: AsyncStream { _ in }
        )

        await viewModel.restoreSessionIfAvailable()
        guard case .failed = viewModel.state else { return XCTFail("Expected failed, got \(viewModel.state)") }
        XCTAssertEqual(try store.loadRefreshToken(), "first-account-token")
        XCTAssertEqual(cleaner.callCount, 0)

        http.enqueue(.json(Self.grantJSON("second-account", refreshToken: "second-account-token")))
        await viewModel.signIn()

        guard case let .signedIn(session) = viewModel.state else { return XCTFail("Expected signed in, got \(viewModel.state)") }
        XCTAssertEqual(session.accessToken, "second-account")
        XCTAssertEqual(try store.loadRefreshToken(), "second-account-token")
        XCTAssertEqual(cleaner.callCount, 1, "The library cached for the sign-in before must not show under the new one.")
    }

    /// While Reconnect waits in the browser, a request that needs a new token must not refresh the
    /// old grant: that put the library back on screen mid-sign-in and left Cancel nothing to undo.
    @MainActor
    func testRequestDuringReconnectDoesNotRefreshTheOldGrant() async throws {
        let store = InMemoryRefreshTokenStore()
        try store.saveRefreshToken("good-refresh-token")
        let http = ScriptedTokenHTTPClient()
        http.enqueue(.json(Self.grantJSON("refreshed-mid-sign-in")))
        let flow = HangUntilCancelledAuthorizationFlow()
        let expiring = AuthenticatedSession(
            accessToken: "expiring", tokenType: "Bearer", scope: Self.browsingScope, expiresAt: Date().addingTimeInterval(10)
        )
        let viewModel = AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            authorizationFlow: flow,
            tokenClient: SpotifyTokenClient(httpClient: http, random: { _ in 0 }, sleep: { _ in }),
            refreshTokenStore: store,
            signOutDataCleaner: {},
            artworkCacheClearer: {},
            initialState: .signedIn(expiring),
            recoverySignals: AsyncStream { _ in }
        )

        let reconnect = await startSignIn(viewModel, untilLaunched: flow.launch.started)
        guard reconnect.launched else { return XCTFail("signIn() returned without reaching the authorization flow") }

        do {
            _ = try await viewModel.accessToken()
            XCTFail("A request during the browser step must not get a refreshed token")
        } catch let error as SpotifyAPIError {
            guard case .unauthorized = error else { return XCTFail("Expected unauthorized, got \(error)") }
        }
        XCTAssertEqual(http.requestCount, 0, "The old grant is not refreshed while the sign-in runs.")
        XCTAssertEqual(viewModel.state, .signingIn)

        viewModel.cancelSignIn()
        await reconnect.finished.value
        XCTAssertEqual(viewModel.state, .signedIn(expiring))
        XCTAssertEqual(try store.loadRefreshToken(), "good-refresh-token")
    }

    /// While Spotify is busy, the library's requests are cancelled whenever a screen reloads. A
    /// cancelled request must leave the pause alone: it used to turn it into "failed", after which
    /// the next request ignored the Retry-After and asked Spotify again, over and over.
    @MainActor
    func testCancelledRequestDuringACooldownKeepsThePauseAndDoesNotAskSpotify() async throws {
        let store = InMemoryRefreshTokenStore()
        try store.saveRefreshToken("good-refresh-token")
        let http = ScriptedTokenHTTPClient()
        http.enqueue(.json(#"{"error":"rate_limited"}"#, statusCode: 429, headers: ["Retry-After": "90"]))
        let clock = TestClock(Date(timeIntervalSince1970: 90_000))
        let viewModel = AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            tokenClient: SpotifyTokenClient(httpClient: http, now: { clock.now }, random: { _ in 0 }, sleep: { _ in }),
            refreshTokenStore: store,
            signOutDataCleaner: {},
            artworkCacheClearer: {},
            now: { clock.now },
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) },
            recoverySignals: AsyncStream { _ in }
        )

        await viewModel.restoreSessionIfAvailable()
        guard case let .paused(pause) = viewModel.state else { return XCTFail("Expected paused, got \(viewModel.state)") }

        let cancelledRequest = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await viewModel.accessToken()
        }
        _ = try? await cancelledRequest.value

        XCTAssertEqual(viewModel.state, .paused(pause), "A cancelled request says nothing about the sign-in.")
        do {
            _ = try await viewModel.accessToken()
            XCTFail("Expected the cooldown to answer the request")
        } catch let error as SpotifySignInPausedError {
            XCTAssertEqual(error.pause.reason, .busy)
        }
        XCTAssertEqual(http.requestCount, 1, "Spotify is not asked again before its Retry-After ends.")
    }

    /// Reconnect while Spotify is busy, then Cancel: the pause comes back with its retry still
    /// set for when Spotify's Retry-After ends, and requests meanwhile still don't ask Spotify.
    @MainActor
    func testCancelledReconnectFromAPauseKeepsItsRetryAfter() async throws {
        let store = InMemoryRefreshTokenStore()
        try store.saveRefreshToken("good-refresh-token")
        let http = ScriptedTokenHTTPClient()
        http.enqueue(.json(#"{"error":"rate_limited"}"#, statusCode: 429, headers: ["Retry-After": "600"]))
        let clock = TestClock(Date(timeIntervalSince1970: 95_000))
        let sleeper = ManualSleeper()
        let flow = HangUntilCancelledAuthorizationFlow()
        let viewModel = AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            authorizationFlow: flow,
            tokenClient: SpotifyTokenClient(httpClient: http, now: { clock.now }, random: { _ in 0 }, sleep: { _ in }),
            refreshTokenStore: store,
            signOutDataCleaner: {},
            artworkCacheClearer: {},
            now: { clock.now },
            sleep: { try await sleeper.sleep($0) },
            recoverySignals: AsyncStream { _ in }
        )

        await viewModel.restoreSessionIfAvailable()
        guard case let .paused(pause) = viewModel.state else { return XCTFail("Expected paused, got \(viewModel.state)") }
        let firstWait = await sleeper.nextSleep()
        XCTAssertEqual(firstWait, 600)

        clock.now += 100
        let reconnect = await startSignIn(viewModel, untilLaunched: flow.launch.started)
        guard reconnect.launched else { return XCTFail("signIn() returned without reaching the authorization flow") }
        viewModel.cancelSignIn()
        await reconnect.finished.value

        XCTAssertEqual(viewModel.state, .paused(pause))
        let waitAfterCancel = await sleeper.nextSleep()
        XCTAssertEqual(waitAfterCancel, 500, "The retry is set up again for when the Retry-After ends.")
        do {
            _ = try await viewModel.accessToken()
            XCTFail("Expected the cooldown to answer the request")
        } catch is SpotifySignInPausedError {}
        XCTAssertEqual(http.requestCount, 1, "Spotify is not asked again before its Retry-After ends.")
    }

    /// A 429 whose Retry-After is zero doesn't make the next try come at once.
    @MainActor
    func testZeroRetryAfterStillWaitsTheBackoff() async throws {
        let store = InMemoryRefreshTokenStore()
        try store.saveRefreshToken("good-refresh-token")
        let http = ScriptedTokenHTTPClient()
        http.enqueue(.json(#"{"error":"rate_limited"}"#, statusCode: 429, headers: ["Retry-After": "0"]), count: 3)
        let clock = TestClock(Date(timeIntervalSince1970: 97_000))
        let viewModel = AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            tokenClient: SpotifyTokenClient(httpClient: http, now: { clock.now }, random: { _ in 0 }, sleep: { _ in }),
            refreshTokenStore: store,
            signOutDataCleaner: {},
            artworkCacheClearer: {},
            now: { clock.now },
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) },
            recoverySignals: AsyncStream { _ in }
        )

        await viewModel.restoreSessionIfAvailable()

        guard case let .paused(pause) = viewModel.state else { return XCTFail("Expected paused, got \(viewModel.state)") }
        XCTAssertEqual(pause.retryAt, clock.now.addingTimeInterval(AuthViewModel.temporaryFailureCooldown))
    }

    func testTemporaryFailureCooldownDoublesUpToFiveMinutes() {
        let waits = (0..<7).map { AuthViewModel.temporaryFailureCooldown(afterFailures: $0) }
        XCTAssertEqual(waits, [30, 60, 120, 240, 300, 300, 300])
        XCTAssertEqual(AuthViewModel.temporaryFailureCooldown(afterFailures: 1_000), 300)
    }

    /// Offline for a long time: each failed try waits twice as long as the one before, and a
    /// refresh that works starts over at 30 s.
    @MainActor
    func testPausedRetriesBackOffAndStartOverAfterARefreshThatWorks() async throws {
        let store = InMemoryRefreshTokenStore()
        try store.saveRefreshToken("good-refresh-token")
        let http = ScriptedTokenHTTPClient()
        http.enqueue(.failure(URLError(.notConnectedToInternet)), count: 3)
        let clock = TestClock(Date(timeIntervalSince1970: 80_000))
        let sleeper = ManualSleeper()
        let viewModel = AuthViewModel(
            settings: makeSettings(clientID: "client-id"),
            tokenClient: SpotifyTokenClient(httpClient: http, now: { clock.now }, random: { _ in 0 }, sleep: { _ in }),
            refreshTokenStore: store,
            signOutDataCleaner: {},
            artworkCacheClearer: {},
            now: { clock.now },
            sleep: { try await sleeper.sleep($0) },
            recoverySignals: AsyncStream { _ in }
        )

        await viewModel.restoreSessionIfAvailable()
        let firstWait = await sleeper.nextSleep()
        XCTAssertEqual(firstWait, 30)

        clock.now += 30
        http.enqueue(.failure(URLError(.notConnectedToInternet)), count: 3)
        await sleeper.wake()
        let secondWait = await sleeper.nextSleep()
        XCTAssertEqual(secondWait, 60)

        // The next request after that wait signs back in. It awaits the refresh itself, so the
        // refresh has fully settled when it returns.
        clock.now += 60
        http.enqueue(.json(Self.grantJSON("back")))
        let token = try await viewModel.accessToken()
        XCTAssertEqual(token, "back")

        // The network drops again and Spotify rejects the token in use: a fresh failure.
        http.enqueue(.failure(URLError(.notConnectedToInternet)), count: 3)
        do {
            _ = try await viewModel.refreshAccessTokenAfterUnauthorized(rejectedToken: "back")
            XCTFail("Expected the refresh to fail while offline")
        } catch is SpotifySignInPausedError {}
        let waitAfterSuccess = await sleeper.nextSleep()
        XCTAssertEqual(waitAfterSuccess, 30)
    }

    @MainActor
    private func signedInSession(of viewModel: AuthViewModel) async -> AuthenticatedSession {
        for await state in viewModel.$state.values {
            if case let .signedIn(session) = state { return session }
        }
        fatalError("The state publisher ended")
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var now: Date {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

private final class RetryDelayLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []
    func append(_ delay: TimeInterval) { lock.withLock { recorded.append(delay) } }
    var values: [TimeInterval] { lock.withLock { recorded } }
}

/// A sleep that ends only when the test says so, reporting each requested delay.
private actor ManualSleeper {
    private var sleepers: [CheckedContinuation<Void, Never>] = []
    private var delays: [TimeInterval] = []
    private var delayWaiters: [CheckedContinuation<TimeInterval, Never>] = []

    func sleep(_ delay: TimeInterval) async throws {
        // One step: by the time a test hears the delay, this sleep can already be woken.
        await withCheckedContinuation { continuation in
            sleepers.append(continuation)
            if delayWaiters.isEmpty {
                delays.append(delay)
            } else {
                delayWaiters.removeFirst().resume(returning: delay)
            }
        }
        try Task.checkCancellation()
    }

    func nextSleep() async -> TimeInterval {
        if !delays.isEmpty { return delays.removeFirst() }
        return await withCheckedContinuation { delayWaiters.append($0) }
    }

    func wake() {
        let waiting = sleepers
        sleepers.removeAll()
        waiting.forEach { $0.resume() }
    }
}

/// /api/token answers in the order the test queues them; it can queue more mid-test.
private final class ScriptedTokenHTTPClient: HTTPClient, @unchecked Sendable {
    enum Answer {
        case json(String, statusCode: Int = 200, headers: [String: String] = [:])
        case failure(Error)
    }

    private let lock = NSLock()
    private var answers: [Answer] = []
    private var count = 0

    var requestCount: Int { lock.withLock { count } }

    func enqueue(_ answer: Answer, count: Int = 1) {
        lock.withLock { answers += Array(repeating: answer, count: count) }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let answer: Answer? = lock.withLock {
            count += 1
            return answers.isEmpty ? nil : answers.removeFirst()
        }
        switch answer {
        case nil:
            throw URLError(.badServerResponse)
        case let .failure(error):
            throw error
        case let .json(body, statusCode, headers):
            return (
                Data(body.utf8),
                HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: headers)!
            )
        }
    }
}
