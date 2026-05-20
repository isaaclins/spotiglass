import Foundation

@MainActor
final class AuthViewModel: ObservableObject {
    @Published var clientID: String {
        didSet {
            settings.clientID = clientID
        }
    }
    @Published private(set) var state: AppConnectionState

    private var currentSession: AuthenticatedSession?
    private var settings: SpotifyAuthSettings
    private let authorizationFlow: any SpotifyAuthorizationFlowing
    private var signInTask: Task<Void, Never>?
    private var signInRetryCooldownUntil: Date?
    private let tokenClient: SpotifyTokenClient
    private let refreshTokenStore: RefreshTokenStore
    private let signOutDataCleaner: () -> Void
    private var inFlightRefreshTask: Task<String, Error>?
    private var refreshCooldownUntil: Date?
    private var refreshCooldownError: Error?

    init(
        settings: SpotifyAuthSettings = SpotifyAuthSettings(),
        authorizationFlow: any SpotifyAuthorizationFlowing = SpotifyAuthorizationFlow(),
        tokenClient: SpotifyTokenClient = SpotifyTokenClient(),
        refreshTokenStore: RefreshTokenStore = KeychainRefreshTokenStore(),
        signOutDataCleaner: @escaping () -> Void = AuthViewModel.defaultSignOutDataCleaner,
        initialState: AppConnectionState = .signedOut
    ) {
        self.settings = settings
        self.clientID = settings.clientID
        self.authorizationFlow = authorizationFlow
        self.tokenClient = tokenClient
        self.refreshTokenStore = refreshTokenStore
        self.signOutDataCleaner = signOutDataCleaner
        self.state = initialState
    }

    static let defaultSignOutDataCleaner: () -> Void = {
        // Wipe the on-disk Spotify cache (playlist names, track titles,
        // selected playlist, last user ID) so that signing out — or signing
        // out and signing back in as a different Spotify account — does not
        // leak the previous account's library through the cache layer.
        guard let cache = try? SpotifyLocalCache() else { return }
        try? cache.clear()
        Task { await ArtworkImageStore.shared.clearAllCachedImages() }
    }

    func restoreSessionIfAvailable() async {
        guard currentSession == nil else { return }
        do {
            guard let refreshToken = try refreshTokenStore.loadRefreshToken(), !settings.clientID.isEmpty else {
                state = .signedOut
                return
            }
            _ = try await refreshAccessTokenSingleFlight(refreshToken: refreshToken, previousSession: nil)
        } catch {
            handleRefreshFailure(error: error)
        }
    }

    func signIn() async {
        guard signInTask == nil, !isSignInRetryCoolingDown else { return }
        state = .signingIn
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performSignIn()
        }
        signInTask = task
        await task.value
        signInTask = nil
    }

    /// Stops an in-progress browser sign-in and closes the loopback listener. Safe to call when not signing in.
    func cancelSignIn() {
        signInTask?.cancel()
        if case .signingIn = state {
            state = .signedOut
        }
    }

    var isSignInRetryCoolingDown: Bool {
        guard let signInRetryCooldownUntil else { return false }
        return signInRetryCooldownUntil > Date()
    }

    private func performSignIn() async {
        do {
            let authorizationCode = try await authorizationFlow.requestAuthorizationCode(clientID: clientID)
            let configuration = try SpotifyAuthConfiguration(clientID: clientID, redirectURI: authorizationCode.redirectURI)
            let grant = try await tokenClient.exchangeAuthorizationCode(
                clientID: configuration.clientID,
                code: authorizationCode.code,
                codeVerifier: authorizationCode.codeVerifier,
                redirectURI: configuration.redirectURI
            )

            if let refreshToken = grant.refreshToken {
                try refreshTokenStore.saveRefreshToken(refreshToken)
            }
            let session = grant.authenticatedSession
            try validateBrowsingScopes(in: session)
            settings.grantedScope = session.scope
            currentSession = session
            signInRetryCooldownUntil = nil
            state = .signedIn(session)
        } catch is CancellationError {
            signInRetryCooldownUntil = nil
            if case .signingIn = state {
                state = .signedOut
            }
        } catch {
            if Task.isCancelled {
                signInRetryCooldownUntil = nil
                state = .signedOut
                return
            }
            signInRetryCooldownUntil = Date().addingTimeInterval(2)
            state = .failed(AuthDisplayError(message: displayMessage(for: error)))
        }
    }

    func signOut() {
        do {
            try refreshTokenStore.deleteRefreshToken()
            settings.grantedScope = nil
            currentSession = nil
            signOutDataCleaner()
            state = .signedOut
        } catch {
            state = .failed(AuthDisplayError(message: displayMessage(for: error)))
        }
    }

    private func refreshAccessToken(refreshToken: String, previousSession: AuthenticatedSession?) async throws {
        state = .refreshing(previousSession)
        let configuration = try SpotifyAuthConfiguration(
            clientID: clientID,
            redirectURI: SpotifyAuthConfiguration.loopbackRedirectURI()
        )
        let grant = try await tokenClient.refreshAccessToken(clientID: configuration.clientID, refreshToken: refreshToken)
        if let replacementRefreshToken = grant.refreshToken {
            try refreshTokenStore.saveRefreshToken(replacementRefreshToken)
        }
        let restoredSession = previousSession?.refreshed(with: grant) ?? grant.authenticatedSession
        let session = sessionWithPersistedScopeIfNeeded(restoredSession)
        try validateBrowsingScopes(in: session)
        settings.grantedScope = session.scope
        currentSession = session
        state = .signedIn(session)
    }

    private func refreshAccessTokenSingleFlight(
        refreshToken: String,
        previousSession: AuthenticatedSession?
    ) async throws -> String {
        if let cooldownUntil = refreshCooldownUntil,
           cooldownUntil > Date(),
           let refreshCooldownError {
            throw refreshCooldownError
        }

        if let inFlightRefreshTask {
            return try await inFlightRefreshTask.value
        }

        let task = Task<String, Error> { @MainActor [weak self] in
            guard let self else { throw SpotifyAPIError.unauthorized }
            do {
                try await self.refreshAccessToken(refreshToken: refreshToken, previousSession: previousSession)
                self.refreshCooldownUntil = nil
                self.refreshCooldownError = nil
                guard let token = self.currentSession?.accessToken else {
                    throw SpotifyAPIError.unauthorized
                }
                return token
            } catch {
                if self.isRefreshRetryExhaustedError(error) {
                    self.refreshCooldownUntil = Date().addingTimeInterval(30)
                    self.refreshCooldownError = error
                } else {
                    self.refreshCooldownUntil = nil
                    self.refreshCooldownError = nil
                }
                throw error
            }
        }

        inFlightRefreshTask = task
        defer { inFlightRefreshTask = nil }
        return try await task.value
    }

    private func handleRefreshFailure(error: Error) {
        // If Spotify rejected the refresh with an OAuth-spec error (HTTP 4xx),
        // the stored refresh token is no longer usable. Wipe it from the
        // Keychain and clear local cached library data so the user starts the
        // next sign-in clean instead of repeatedly retrying a dead token.
        if isUnrecoverableRefreshError(error) {
            try? refreshTokenStore.deleteRefreshToken()
            settings.grantedScope = nil
            currentSession = nil
            signOutDataCleaner()
        }
        state = .failed(AuthDisplayError(message: displayMessage(for: error)))
    }

    private func isUnrecoverableRefreshError(_ error: Error) -> Bool {
        if let tokenError = error as? SpotifyTokenClientError,
           case let .httpError(status, _, _, _) = tokenError,
           (400..<500).contains(status) {
            return true
        }
        return false
    }

    private func isRefreshRetryExhaustedError(_ error: Error) -> Bool {
        guard let tokenError = error as? SpotifyTokenClientError,
              case let .httpError(status, _, _, _) = tokenError else {
            return (error as? URLError) != nil
        }
        return status == 429 || (500...599).contains(status)
    }

    private func sessionWithPersistedScopeIfNeeded(_ session: AuthenticatedSession) -> AuthenticatedSession {
        guard session.scope == nil, let grantedScope = settings.grantedScope else {
            return session
        }
        return AuthenticatedSession(
            accessToken: session.accessToken,
            tokenType: session.tokenType,
            scope: grantedScope,
            expiresAt: session.expiresAt
        )
    }

    private func validateBrowsingScopes(in session: AuthenticatedSession) throws {
        guard session.includesRequiredBrowsingScopes() else {
            throw SpotifyAPIError.insufficientScope(
                requiredScopes: SpotifyAuthConfiguration.requiredBrowsingScopes,
                message: SpotiglassL10n.string("auth.insufficientScope.message"),
                details: nil
            )
        }
    }

    private func displayMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        if let apiError = error as? SpotifyAPIError {
            return apiError.userMessage
        }
        if let urlError = error as? URLError {
            return Self.urlErrorMessage(urlError)
        }
        if error is DecodingError {
            return SpotiglassL10n.string("auth.error.decode")
        }
        return Self.genericAuthFailureMessage
    }

    private static var genericAuthFailureMessage: String {
        SpotiglassL10n.string("auth.error.generic")
    }

    private static func urlErrorMessage(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet:
            return SpotiglassL10n.string("auth.error.offline")
        case .timedOut:
            return SpotiglassL10n.string("auth.error.timeout")
        case .cannotFindHost, .dnsLookupFailed:
            return SpotiglassL10n.string("auth.error.dns")
        case .cannotConnectToHost, .networkConnectionLost:
            return SpotiglassL10n.string("auth.error.network")
        case .secureConnectionFailed, .serverCertificateUntrusted, .clientCertificateRejected:
            return SpotiglassL10n.string("auth.error.tls")
        case .cancelled:
            return SpotiglassL10n.string("auth.error.cancelled")
        default:
            let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || text.localizedCaseInsensitiveContains("couldn’t be completed") || text.localizedCaseInsensitiveContains("couldn't be completed") {
                return genericAuthFailureMessage
            }
            return text
        }
    }
}

extension AuthViewModel: PlaybackAccessTokenProviding {
    func playbackAccessToken() async throws -> String {
        if let currentSession, !currentSession.expires(within: 60) {
            return currentSession.accessToken
        }
        return try await refreshedPlaybackAccessToken()
    }

    func refreshedPlaybackAccessToken() async throws -> String {
        guard let refreshToken = try refreshTokenStore.loadRefreshToken() else {
            throw SpotifyAPIError.unauthorized
        }
        let previousSession = currentSession
        do {
            return try await refreshAccessTokenSingleFlight(
                refreshToken: refreshToken,
                previousSession: previousSession
            )
        } catch {
            // Mirror the same Keychain wipe + state reset used by
            // restoreSessionIfAvailable / refreshAccessTokenIfNeeded so the
            // browsing and playback sides stay in agreement when a refresh
            // token gets revoked mid-session.
            handleRefreshFailure(error: error)
            throw SpotifyAPIError.unauthorized
        }
    }
}

extension AuthViewModel: SpotifyAccessTokenProviding {
    func accessToken() async throws -> String {
        try await playbackAccessToken()
    }

    func refreshAccessTokenAfterUnauthorized() async throws -> String {
        try await refreshedPlaybackAccessToken()
    }
}

extension AuthViewModel {
    static func preview(state: AppConnectionState = .signedOut) -> AuthViewModel {
        AuthViewModel(initialState: state)
    }
}
