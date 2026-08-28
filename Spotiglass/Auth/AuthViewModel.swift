import Foundation

private struct AuthTransitionInvalidatedError: Error {}

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
    private var signInOwnerGeneration: Int?
    private var signInRetryCooldownUntil: Date?
    private let tokenClient: SpotifyTokenClient
    private let refreshTokenStore: RefreshTokenStore
    private let signOutDataCleaner: () -> Void
    private let artworkCacheClearer: () async -> Void
    private let now: () -> Date
    private var inFlightRefreshTask: Task<String, Error>?
    private var authTransitionGeneration = 0
    private var refreshCooldownUntil: Date?
    private var refreshCooldownError: Error?

    init(
        settings: SpotifyAuthSettings = SpotifyAuthSettings(),
        authorizationFlow: any SpotifyAuthorizationFlowing = SpotifyAuthorizationFlow(),
        tokenClient: SpotifyTokenClient = SpotifyTokenClient(),
        refreshTokenStore: RefreshTokenStore = KeychainRefreshTokenStore(),
        signOutDataCleaner: @escaping () -> Void = AuthViewModel.defaultSignOutDataCleaner,
        artworkCacheClearer: @escaping () async -> Void = { await ArtworkImageStore.shared.clearAllCachedImages() },
        initialState: AppConnectionState = .signedOut,
        now: @escaping () -> Date = Date.init
    ) {
        self.settings = settings
        self.clientID = settings.clientID
        self.authorizationFlow = authorizationFlow
        self.tokenClient = tokenClient
        self.refreshTokenStore = refreshTokenStore
        self.signOutDataCleaner = signOutDataCleaner
        self.artworkCacheClearer = artworkCacheClearer
        self.now = now
        self.state = initialState
    }

    static let defaultSignOutDataCleaner: () -> Void = {
        // Wipe account-bound library data so signing out, or signing out
        // and signing back in as a different Spotify account, cannot leak
        // the previous account's library through the cache layer. Public GET
        // catalog responses and per-account pins have separate ownership.
        guard let cache = try? SpotifyLocalCache() else { return }
        try? cache.clearPrivateAccountData()
    }

    func restoreSessionIfAvailable() async {
        guard currentSession == nil else { return }
        let generation = authTransitionGeneration
        do {
            guard let refreshToken = try refreshTokenStore.loadRefreshToken(), !settings.clientID.isEmpty else {
                guard generation == authTransitionGeneration else { return }
                state = .signedOut
                return
            }
            _ = try await refreshAccessTokenSingleFlight(
                refreshToken: refreshToken,
                previousSession: nil,
                generation: generation
            )
        } catch {
            guard generation == authTransitionGeneration else { return }
            await handleRefreshFailure(error: error)
        }
    }

    func signIn() async {
        guard signInTask == nil, !isSignInRetryCoolingDown else { return }
        let isReconnect = state.isConnectedOrRefreshing || currentSession != nil
        let generation = invalidateAuthOperations()
        currentSession = nil
        do {
            try refreshTokenStore.deleteRefreshToken()
            if isReconnect {
                await clearSignOutData()
            }
        } catch {
            state = .failed(AuthDisplayError(message: displayMessage(for: error)))
            return
        }
        state = .signingIn
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performSignIn(generation: generation)
        }
        signInTask = task
        signInOwnerGeneration = generation
        await task.value
        if signInOwnerGeneration == generation {
            signInTask = nil
            signInOwnerGeneration = nil
        }
    }

    /// Stops an in-progress browser sign-in and closes the loopback listener. Safe to call when not signing in.
    func cancelSignIn() {
        guard signInTask != nil else { return }
        _ = invalidateAuthOperations()
        if case .signingIn = state {
            state = .signedOut
        }
    }

    var isSignInRetryCoolingDown: Bool {
        guard let signInRetryCooldownUntil else { return false }
        return signInRetryCooldownUntil > now()
    }

    private func performSignIn(generation: Int) async {
        do {
            try ensureAuthTransitionIsCurrent(generation)
            let authorizationCode = try await authorizationFlow.requestAuthorizationCode(clientID: clientID)
            try ensureAuthTransitionIsCurrent(generation)
            let configuration = try SpotifyAuthConfiguration(clientID: clientID, redirectURI: authorizationCode.redirectURI)
            let grant = try await tokenClient.exchangeAuthorizationCode(
                clientID: configuration.clientID,
                code: authorizationCode.code,
                codeVerifier: authorizationCode.codeVerifier,
                redirectURI: configuration.redirectURI
            )
            try ensureAuthTransitionIsCurrent(generation)

            if let refreshToken = grant.refreshToken {
                try refreshTokenStore.saveRefreshToken(refreshToken)
            }
            let session = grant.authenticatedSession
            try validateBrowsingScopes(in: session)
            settings.grantedScope = session.scope
            currentSession = session
            signInRetryCooldownUntil = nil
            state = .signedIn(session)
        } catch is AuthTransitionInvalidatedError {
            return
        } catch is CancellationError {
            guard generation == authTransitionGeneration else { return }
            signInRetryCooldownUntil = nil
            if case .signingIn = state {
                state = .signedOut
            }
        } catch {
            guard generation == authTransitionGeneration else { return }
            if Task.isCancelled {
                signInRetryCooldownUntil = nil
                state = .signedOut
                return
            }
            signInRetryCooldownUntil = now().addingTimeInterval(2)
            state = .failed(AuthDisplayError(message: displayMessage(for: error)))
        }
    }

    func signOut() async {
        let generation = invalidateAuthOperations()
        do {
            try refreshTokenStore.deleteRefreshToken()
            settings.grantedScope = nil
            currentSession = nil
            await clearSignOutData()
            guard generation == authTransitionGeneration else { return }
            state = .signedOut
        } catch {
            state = .failed(AuthDisplayError(message: displayMessage(for: error)))
        }
    }

    private func refreshAccessToken(
        refreshToken: String,
        previousSession: AuthenticatedSession?,
        generation: Int
    ) async throws {
        try ensureAuthTransitionIsCurrent(generation)
        state = .refreshing(previousSession)
        let configuration = try SpotifyAuthConfiguration(
            clientID: clientID,
            redirectURI: SpotifyAuthConfiguration.loopbackRedirectURI()
        )
        let grant = try await tokenClient.refreshAccessToken(clientID: configuration.clientID, refreshToken: refreshToken)
        try ensureAuthTransitionIsCurrent(generation)
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
        previousSession: AuthenticatedSession?,
        generation: Int
    ) async throws -> String {
        try ensureAuthTransitionIsCurrent(generation)
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
                try await self.refreshAccessToken(
                    refreshToken: refreshToken,
                    previousSession: previousSession,
                    generation: generation
                )
                try self.ensureAuthTransitionIsCurrent(generation)
                self.refreshCooldownUntil = nil
                self.refreshCooldownError = nil
                guard let token = self.currentSession?.accessToken else {
                    throw SpotifyAPIError.unauthorized
                }
                return token
            } catch {
                guard generation == self.authTransitionGeneration else {
                    throw AuthTransitionInvalidatedError()
                }
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
        defer {
            if authTransitionGeneration == generation {
                inFlightRefreshTask = nil
            }
        }
        return try await task.value
    }

    private func invalidateAuthOperations() -> Int {
        authTransitionGeneration &+= 1
        signInTask?.cancel()
        inFlightRefreshTask?.cancel()
        inFlightRefreshTask = nil
        return authTransitionGeneration
    }

    private func ensureAuthTransitionIsCurrent(_ generation: Int) throws {
        guard generation == authTransitionGeneration else {
            throw AuthTransitionInvalidatedError()
        }
        try Task.checkCancellation()
    }

    private func handleRefreshFailure(error: Error) async {
        // If Spotify rejected the refresh with an OAuth-spec error (HTTP 4xx),
        // the stored refresh token is no longer usable. Wipe it from the
        // Keychain and clear local cached library data so the user starts the
        // next sign-in clean instead of repeatedly retrying a dead token.
        if isUnrecoverableRefreshError(error) {
            let generation = authTransitionGeneration
            try? refreshTokenStore.deleteRefreshToken()
            settings.grantedScope = nil
            currentSession = nil
            await clearSignOutData()
            guard generation == authTransitionGeneration else { return }
        }
        state = .failed(AuthDisplayError(message: displayMessage(for: error)))
    }

    private func clearSignOutData() async {
        signOutDataCleaner()
        await artworkCacheClearer()
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
        // The sentence stays free of OAuth codes and socket steps, but they must
        // not be dropped either: the log is where a bug report picks them up.
        // Every auth failure routes through here, so this is the one place that
        // has to remember (#186).
        if let callbackError = error as? LoopbackOAuthCallbackError,
           let details = callbackError.diagnosticDetails {
            SpotiglassLog.error(.auth, details)
        }
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
        let generation = authTransitionGeneration
        do {
            return try await refreshAccessTokenSingleFlight(
                refreshToken: refreshToken,
                previousSession: previousSession,
                generation: generation
            )
        } catch {
            guard generation == authTransitionGeneration else {
                throw CancellationError()
            }
            // Mirror the same Keychain wipe + state reset used by
            // restoreSessionIfAvailable / refreshAccessTokenIfNeeded so the
            // browsing and playback sides stay in agreement when a refresh
            // token gets revoked mid-session.
            await handleRefreshFailure(error: error)
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
