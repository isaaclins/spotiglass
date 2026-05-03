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
    private let authorizationFlow: SpotifyAuthorizationFlow
    private let tokenClient: SpotifyTokenClient
    private let refreshTokenStore: RefreshTokenStore
    private let signOutDataCleaner: () -> Void

    init(
        settings: SpotifyAuthSettings = SpotifyAuthSettings(),
        authorizationFlow: SpotifyAuthorizationFlow = SpotifyAuthorizationFlow(),
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
            try await refreshAccessToken(refreshToken: refreshToken, previousSession: nil)
        } catch {
            handleRefreshFailure(error: error)
        }
    }

    func signIn() async {
        do {
            state = .signingIn
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
            state = .signedIn(session)
        } catch {
            state = .failed(AuthDisplayError(message: displayMessage(for: error)))
        }
    }

    func refreshAccessTokenIfNeeded() async {
        guard let session = currentSession, session.expires(within: 60) else { return }
        do {
            guard let refreshToken = try refreshTokenStore.loadRefreshToken() else {
                state = .signedOut
                return
            }
            try await refreshAccessToken(refreshToken: refreshToken, previousSession: session)
        } catch {
            handleRefreshFailure(error: error)
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
           case let .httpError(status, _) = tokenError,
           (400..<500).contains(status) {
            return true
        }
        return false
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
                message: "Your current Spotify session is missing playlist or Liked Songs permissions. Disconnect and connect again to grant required scopes.",
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
            return "Spotify returned a response Spotiglass could not read. Check your connection, try again, or disconnect and connect Spotify again."
        }
        return Self.genericAuthFailureMessage
    }

    private static let genericAuthFailureMessage =
        "Something went wrong. Check your connection, try again, or disconnect and connect Spotify again."

    private static func urlErrorMessage(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet:
            return "You appear to be offline. Check your network, then try again."
        case .timedOut:
            return "The connection to Spotify timed out. Try again."
        case .cannotFindHost, .dnsLookupFailed:
            return "Could not reach Spotify. Check your network and DNS settings."
        case .cannotConnectToHost, .networkConnectionLost:
            return "Could not connect to Spotify. Check your network, then try again."
        case .secureConnectionFailed, .serverCertificateUntrusted, .clientCertificateRejected:
            return "Could not establish a secure connection to Spotify. Check your network or VPN, then try again."
        case .cancelled:
            return "The request was cancelled. Try again."
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
            try await refreshAccessToken(refreshToken: refreshToken, previousSession: previousSession)
        } catch {
            // Mirror the same Keychain wipe + state reset used by
            // restoreSessionIfAvailable / refreshAccessTokenIfNeeded so the
            // browsing and playback sides stay in agreement when a refresh
            // token gets revoked mid-session.
            handleRefreshFailure(error: error)
            throw SpotifyAPIError.unauthorized
        }
        guard let currentSession else {
            throw SpotifyAPIError.unauthorized
        }
        return currentSession.accessToken
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
