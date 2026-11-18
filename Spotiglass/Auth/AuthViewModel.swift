import AppKit
import Foundation
import Network
import os

private struct AuthTransitionInvalidatedError: Error {}

/// Moments a paused sign-in should try again: the network came back, or the Mac woke (#593).
enum AuthRecoverySignals {
    static func live() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            // The monitor reports the current path first; only a path that comes back counts.
            let wasSatisfied = OSAllocatedUnfairLock<Bool?>(initialState: nil)
            monitor.pathUpdateHandler = { path in
                let isSatisfied = path.status == .satisfied
                let cameBack = wasSatisfied.withLock { previous in
                    defer { previous = isSatisfied }
                    return previous == false && isSatisfied
                }
                if cameBack { continuation.yield() }
            }
            monitor.start(queue: DispatchQueue(label: "com.isaaclins.spotiglass.auth-recovery"))
            let wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: nil
            ) { _ in
                continuation.yield()
            }
            continuation.onTermination = { _ in
                monitor.cancel()
                NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            }
        }
    }
}

@MainActor
final class AuthViewModel: ObservableObject {
    @Published var clientID: String {
        didSet {
            settings.clientID = clientID
        }
    }
    @Published private(set) var state: AppConnectionState
    /// `true` from the moment ``signOut()`` deletes the saved sign-in until it publishes
    /// `.signedOut`. `state` still says signed in while the caches are cleared, but that session
    /// is already gone and must not be shown or reused.
    @Published private(set) var isSigningOut = false

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
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var inFlightRefreshTask: Task<String, Error>?
    private var authTransitionGeneration = 0
    private var refreshCooldownUntil: Date?
    /// Temporary failures in a row without a refresh that worked; each one doubles the wait.
    private var temporaryFailureStreak = 0
    /// Tries a paused sign-in again once Spotify's Retry-After (or the busy cooldown) is over.
    private var pausedRetryTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?

    init(
        settings: SpotifyAuthSettings = SpotifyAuthSettings(),
        authorizationFlow: any SpotifyAuthorizationFlowing = SpotifyAuthorizationFlow(),
        tokenClient: SpotifyTokenClient = SpotifyTokenClient(),
        refreshTokenStore: RefreshTokenStore = KeychainRefreshTokenStore(),
        signOutDataCleaner: @escaping () -> Void = AuthViewModel.defaultSignOutDataCleaner,
        artworkCacheClearer: @escaping () async -> Void = { await ArtworkImageStore.shared.clearAllCachedImages() },
        initialState: AppConnectionState = .signedOut,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { delay in
            try await Task.sleep(for: .seconds(delay))
        },
        recoverySignals: AsyncStream<Void> = AuthRecoverySignals.live()
    ) {
        self.settings = settings
        self.clientID = settings.clientID
        self.authorizationFlow = authorizationFlow
        self.tokenClient = tokenClient
        self.refreshTokenStore = refreshTokenStore
        self.signOutDataCleaner = signOutDataCleaner
        self.artworkCacheClearer = artworkCacheClearer
        self.now = now
        self.sleep = sleep
        self.state = initialState
        recoveryTask = Task { @MainActor [weak self] in
            for await _ in recoverySignals {
                await self?.retryPausedSignIn(waitForBusyCooldown: true)
            }
        }
    }

    deinit {
        recoveryTask?.cancel()
        pausedRetryTask?.cancel()
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
            _ = await handleRefreshFailure(error: error, previousSession: nil)
        }
    }

    func signIn() async {
        guard signInTask == nil, !isSignInRetryCoolingDown else { return }
        // The sign-in from before stays saved and usable until the new grant is: a reconnect
        // that is cancelled, denied or fails leaves it working (#593).
        let stateBeforeSignIn = state
        let sessionBeforeSignIn = currentSession ?? state.pausedOrLiveSession
        let isReconnect = state.isConnectedOrRefreshing || currentSession != nil
        // A sign-in that failed for another reason keeps its token and library caches, and may be
        // another account's: those caches go too once the new grant arrives (#233, #234).
        let replacesSavedSignIn = isReconnect || (try? refreshTokenStore.loadRefreshToken()) != nil
        let generation = invalidateAuthOperations()
        state = .signingIn
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performSignIn(
                generation: generation,
                isReconnect: isReconnect,
                replacesSavedSignIn: replacesSavedSignIn,
                restoring: (stateBeforeSignIn, sessionBeforeSignIn)
            )
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
        let restorePoint = signInRestorePoint
        _ = invalidateAuthOperations()
        signInRestorePoint = restorePoint
        if case .signingIn = state {
            restoreStateBeforeSignIn()
        }
    }

    /// What a cancelled or failed reconnect goes back to; `nil` for a first sign-in.
    private var signInRestorePoint: (state: AppConnectionState, session: AuthenticatedSession?)?

    private func restoreStateBeforeSignIn() {
        guard let restorePoint = signInRestorePoint else {
            state = .signedOut
            return
        }
        signInRestorePoint = nil
        currentSession = restorePoint.session
        switch restorePoint.state {
        case .signedIn:
            state = restorePoint.state
        case let .refreshing(.some(session)):
            // The refresh it showed was cancelled by the sign-in; the next request refreshes.
            state = .signedIn(session)
        case let .paused(pause):
            // Starting the sign-in cancelled the pause's own retry: set it up again, keeping
            // Spotify's Retry-After.
            state = restorePoint.state
            let wait = pause.retryAt.map { max(0, $0.timeIntervalSince(now())) }
                ?? Self.temporaryFailureCooldown(afterFailures: 0)
            refreshCooldownUntil = now().addingTimeInterval(wait)
            schedulePausedRetry(after: wait)
        case .refreshing(.none):
            // The refresh it was waiting on was cancelled by the sign-in: try it again.
            state = .signedOut
            Task { await self.restoreSessionIfAvailable() }
        case .signedOut, .signingIn, .failed:
            state = .signedOut
        }
    }

    var isSignInRetryCoolingDown: Bool {
        guard let signInRetryCooldownUntil else { return false }
        return signInRetryCooldownUntil > now()
    }

    private func performSignIn(
        generation: Int,
        isReconnect: Bool,
        replacesSavedSignIn: Bool,
        restoring restorePoint: (AppConnectionState, AuthenticatedSession?)
    ) async {
        signInRestorePoint = isReconnect ? (restorePoint.0, restorePoint.1) : nil
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

            // Only now does the new grant replace the old one. It may be a different account, so
            // the library caches of the sign-in before go first (#233, #234).
            if replacesSavedSignIn {
                await clearSignOutData()
                try ensureAuthTransitionIsCurrent(generation)
            }
            signInRestorePoint = nil
            if let refreshToken = grant.refreshToken {
                try refreshTokenStore.saveRefreshToken(refreshToken)
            } else {
                try refreshTokenStore.deleteRefreshToken()
            }
            let session = grant.authenticatedSession
            // Persist the server's scope result before validation. A newly
            // authorized token can legitimately omit an optional feature
            // scope; the feature gate needs to remember that fact instead of
            // allowing the next request to discover it through a 403.
            settings.grantedScope = session.scope
            try validateBrowsingScopes(in: session)
            currentSession = session
            signInRetryCooldownUntil = nil
            state = .signedIn(session)
        } catch is AuthTransitionInvalidatedError {
            return
        } catch is CancellationError {
            guard generation == authTransitionGeneration else { return }
            signInRetryCooldownUntil = nil
            if case .signingIn = state {
                restoreStateBeforeSignIn()
            }
        } catch {
            guard generation == authTransitionGeneration else { return }
            if Task.isCancelled {
                signInRetryCooldownUntil = nil
                restoreStateBeforeSignIn()
                return
            }
            signInRetryCooldownUntil = now().addingTimeInterval(2)
            if signInRestorePoint != nil {
                // The reason still reaches the log; the session from before keeps working.
                SpotiglassLog.error(.auth, "Reconnect failed, keeping the previous sign-in: \(error)")
                _ = Self.displayError(for: error)
                restoreStateBeforeSignIn()
            } else {
                state = .failed(Self.displayError(for: error))
            }
        }
    }

    func signOut() async {
        let generation = invalidateAuthOperations()
        isSigningOut = true
        defer {
            if generation == authTransitionGeneration { isSigningOut = false }
        }
        do {
            try refreshTokenStore.deleteRefreshToken()
            settings.grantedScope = nil
            currentSession = nil
            await clearSignOutData()
            guard generation == authTransitionGeneration else { return }
            state = .signedOut
        } catch {
            state = .failed(Self.displayError(for: error))
        }
    }

    private func refreshAccessToken(
        refreshToken: String,
        previousSession: AuthenticatedSession?,
        generation: Int
    ) async throws {
        try ensureAuthTransitionIsCurrent(generation)
        // A paused sign-in keeps its library on screen while it tries again.
        if case .paused = state {} else {
            state = .refreshing(previousSession)
        }
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
        // Spotify may omit `scope` on refresh. In that case the previous
        // session (or the persisted grant used during restore) remains the
        // source of truth. When Spotify does return a scope, save it even if
        // validation below rejects a stale/incomplete session.
        if let returnedScope = grant.scope?.trimmingCharacters(in: .whitespacesAndNewlines), !returnedScope.isEmpty {
            settings.grantedScope = returnedScope
        } else if let sessionScope = session.scope {
            settings.grantedScope = sessionScope
        }
        try validateBrowsingScopes(in: session)
        currentSession = session
        pausedRetryTask?.cancel()
        pausedRetryTask = nil
        temporaryFailureStreak = 0
        state = .signedIn(session)
    }

    private func refreshAccessTokenSingleFlight(
        refreshToken: String,
        previousSession: AuthenticatedSession?,
        generation: Int
    ) async throws -> String {
        try ensureAuthTransitionIsCurrent(generation)
        if let cooldownUntil = refreshCooldownUntil,
           cooldownUntil > now(),
           case let .paused(pause) = state {
            throw SpotifySignInPausedError(pause: pause)
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
                guard let token = self.currentSession?.accessToken else {
                    throw SpotifyAPIError.unauthorized
                }
                return token
            } catch {
                guard generation == self.authTransitionGeneration else {
                    throw AuthTransitionInvalidatedError()
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
        // A new sign-in or refresh takes over from a sign-out still clearing its caches.
        isSigningOut = false
        signInTask?.cancel()
        inFlightRefreshTask?.cancel()
        inFlightRefreshTask = nil
        pausedRetryTask?.cancel()
        pausedRetryTask = nil
        refreshCooldownUntil = nil
        temporaryFailureStreak = 0
        signInRestorePoint = nil
        return authTransitionGeneration
    }

    private func ensureAuthTransitionIsCurrent(_ generation: Int) throws {
        guard generation == authTransitionGeneration else {
            throw AuthTransitionInvalidatedError()
        }
        try Task.checkCancellation()
    }

    /// Settles a failed refresh and returns what the request that asked for it should throw.
    ///
    /// Only a grant Spotify calls dead deletes the sign-in. A temporary problem (no network,
    /// Spotify busy) keeps the token and the library and pauses the sign-in, which tries again by
    /// itself (#593).
    private func handleRefreshFailure(error: Error, previousSession: AuthenticatedSession?) async -> Error {
        if let pausedError = error as? SpotifySignInPausedError {
            return pausedError
        }
        // The request that asked went away (its screen reloaded or closed) before the refresh
        // started. Nothing about the sign-in changed: counting it as a failure dropped a paused
        // sign-in to "failed", and the next request then ignored Spotify's Retry-After.
        if error is CancellationError || error is AuthTransitionInvalidatedError {
            return error
        }
        switch Self.refreshFailureKind(error) {
        case .deadGrant:
            let generation = authTransitionGeneration
            try? refreshTokenStore.deleteRefreshToken()
            settings.grantedScope = nil
            currentSession = nil
            await clearSignOutData()
            guard generation == authTransitionGeneration else { return SpotifyAPIError.unauthorized }
            state = .failed(Self.displayError(for: error))
            return SpotifyAPIError.unauthorized
        case let .temporary(reason, retryAfter):
            // Every request waiting on the same refresh lands here; the first one settled it.
            if let refreshCooldownUntil, refreshCooldownUntil > now(), case let .paused(pause) = state {
                return SpotifySignInPausedError(pause: pause)
            }
            SpotiglassLog.error(.auth, "Sign-in refresh failed for now, keeping the sign-in: \(error)")
            // Spotify's Retry-After when it is longer; a short or zero one doesn't undercut the
            // backoff, or repeated 429s would ask again almost at once.
            let cooldown = max(retryAfter ?? 0, Self.temporaryFailureCooldown(afterFailures: temporaryFailureStreak))
            temporaryFailureStreak += 1
            refreshCooldownUntil = now().addingTimeInterval(cooldown)
            let pause = SpotifySignInPause(
                session: previousSession ?? state.pausedOrLiveSession,
                reason: reason,
                retryAt: reason == .busy ? refreshCooldownUntil : nil
            )
            state = .paused(pause)
            schedulePausedRetry(after: cooldown)
            return SpotifySignInPausedError(pause: pause)
        case .other:
            SpotiglassLog.error(.auth, "Sign-in refresh failed, keeping the saved sign-in: \(error)")
            state = .failed(Self.displayError(for: error))
            return SpotifyAPIError.unauthorized
        }
    }

    /// How long a temporary failure holds back the next refresh, unless the network comes back
    /// or the Mac wakes first. Spotify's own Retry-After replaces it when it sends one.
    static let temporaryFailureCooldown: TimeInterval = 30
    /// The longest a temporary failure waits before trying again by itself.
    static let longestTemporaryFailureCooldown: TimeInterval = 300

    /// 30 s after the first temporary failure, doubling with each one after it up to 5 min, so a
    /// long time offline or a long Spotify outage isn't asked about every 30 s.
    nonisolated static func temporaryFailureCooldown(afterFailures failures: Int) -> TimeInterval {
        min(temporaryFailureCooldown * pow(2, Double(min(failures, 10))), longestTemporaryFailureCooldown)
    }

    private func schedulePausedRetry(after delay: TimeInterval) {
        pausedRetryTask?.cancel()
        let generation = authTransitionGeneration
        let sleep = self.sleep
        pausedRetryTask = Task { @MainActor [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard let self, generation == self.authTransitionGeneration else { return }
            self.pausedRetryTask = nil
            await self.retryPausedSignIn(waitForBusyCooldown: false)
        }
    }

    /// Tries a paused sign-in again. A network or wake signal skips the offline cooldown, but not
    /// a Retry-After Spotify asked for.
    private func retryPausedSignIn(waitForBusyCooldown: Bool) async {
        guard case let .paused(pause) = state else { return }
        if waitForBusyCooldown, pause.reason == .busy,
           let refreshCooldownUntil, refreshCooldownUntil > now() {
            return
        }
        refreshCooldownUntil = nil
        let generation = authTransitionGeneration
        do {
            guard let refreshToken = try refreshTokenStore.loadRefreshToken() else {
                state = .signedOut
                return
            }
            _ = try await refreshAccessTokenSingleFlight(
                refreshToken: refreshToken,
                previousSession: pause.session,
                generation: generation
            )
        } catch {
            guard generation == authTransitionGeneration else { return }
            _ = await handleRefreshFailure(error: error, previousSession: pause.session)
        }
    }

    private func clearSignOutData() async {
        signOutDataCleaner()
        await artworkCacheClearer()
    }

    enum RefreshFailureKind: Equatable {
        /// Spotify says the grant itself is gone: only a new sign-in helps.
        case deadGrant
        /// The grant may well still work; Spotify couldn't be asked right now.
        case temporary(SpotifySignInPause.Reason, retryAfter: TimeInterval?)
        /// Anything else: shown, but the saved sign-in stays.
        case other
    }

    nonisolated static func refreshFailureKind(_ error: Error) -> RefreshFailureKind {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .networkConnectionLost:
                return .temporary(.offline, retryAfter: nil)
            default:
                return .temporary(.unreachable, retryAfter: nil)
            }
        }
        guard let tokenError = error as? SpotifyTokenClientError,
              case let .httpError(status, _, oauthError, retryAfter) = tokenError else {
            return .other
        }
        if status == 429 {
            return .temporary(.busy, retryAfter: retryAfter)
        }
        if (500...599).contains(status) {
            return .temporary(.busy, retryAfter: retryAfter)
        }
        switch oauthError?.lowercased() {
        case "invalid_grant", "invalid_client", "unauthorized_client":
            return .deadGrant
        default:
            return .other
        }
    }

    private func sessionWithPersistedScopeIfNeeded(_ session: AuthenticatedSession) -> AuthenticatedSession {
        guard session.scope == nil,
              let persistedScope = settings.grantedScope?.trimmingCharacters(in: .whitespacesAndNewlines),
              !persistedScope.isEmpty else {
            return session
        }
        return AuthenticatedSession(
            accessToken: session.accessToken,
            tokenType: session.tokenType,
            scope: persistedScope,
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

    private static func displayError(for error: Error) -> AuthDisplayError {
        // The sentence stays free of OAuth codes and socket steps, but they must
        // not be dropped either: the log is where a bug report picks them up.
        // Every auth failure routes through here, so this is the one place that
        // has to remember (#186).
        if let callbackError = error as? LoopbackOAuthCallbackError,
           let details = callbackError.diagnosticDetails {
            SpotiglassLog.error(.auth, details)
        }
        // The error itself is kept, not its sentence: the sentence is looked up each time it
        // is shown, so it follows a language switch (#571).
        return AuthDisplayError(message: displayMessage(for: error))
    }

    private static func displayMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        if let apiError = error as? SpotifyAPIError {
            return apiError.userMessage
        }
        if let urlError = error as? URLError {
            // A code that isn't a connection problem keeps sign-in's generic sentence.
            return SpotifyAPIError.networkMessage(for: urlError, fallback: Self.genericAuthFailureMessage)
        }
        if error is DecodingError {
            return SpotiglassL10n.string("auth.error.decode")
        }
        return Self.genericAuthFailureMessage
    }

    private static var genericAuthFailureMessage: String {
        SpotiglassL10n.string("auth.error.generic")
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
        // While a browser sign-in runs, the old grant isn't refreshed: that would put the library
        // back on screen in the middle of the sign-in, and a dead-grant answer would delete the
        // token the reconnect falls back to (#593).
        guard signInTask == nil else { throw SpotifyAPIError.unauthorized }
        guard let refreshToken = try refreshTokenStore.loadRefreshToken() else {
            throw SpotifyAPIError.unauthorized
        }
        let previousSession = currentSession ?? state.pausedOrLiveSession
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
            // The same settling as restoreSessionIfAvailable, so browsing and playback agree.
            // A temporary failure throws the calm "offline" / "Spotify is busy" error, not
            // "session expired" (#593).
            throw await handleRefreshFailure(error: error, previousSession: previousSession)
        }
    }
}

extension AuthViewModel: SpotifyScopeProviding {
    func grantedScopes() async -> Set<String> {
        if let currentSession {
            return currentSession.grantedScopes
        }
        return switch state {
        case let .signedIn(session), let .refreshing(.some(session)):
            session.grantedScopes
        case let .paused(pause):
            // A launch while offline has no session yet: the scope saved with the grant still holds.
            pause.session?.grantedScopes
                ?? Set((settings.grantedScope ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
        case .signedOut, .signingIn, .failed, .refreshing(.none):
            []
        }
    }
}

extension AuthViewModel: SpotifyAccessTokenProviding {
    func accessToken() async throws -> String {
        try await playbackAccessToken()
    }

    func refreshAccessTokenAfterUnauthorized(rejectedToken: String) async throws -> String {
        // Two requests sent with the same expired token both get a 401. When
        // the second 401 arrives after the first one's refresh already
        // finished, the session holds a newer token: retry with it instead of
        // refreshing again.
        if let currentSession,
           currentSession.accessToken != rejectedToken,
           !currentSession.expires(within: 60) {
            return currentSession.accessToken
        }
        return try await refreshedPlaybackAccessToken()
    }
}

extension AuthViewModel {
    static func preview(state: AppConnectionState = .signedOut) -> AuthViewModel {
        AuthViewModel(initialState: state)
    }
}

private extension AppConnectionState {
    var pausedOrLiveSession: AuthenticatedSession? {
        switch self {
        case let .signedIn(session), let .refreshing(.some(session)): session
        case let .paused(pause): pause.session
        case .signedOut, .signingIn, .failed, .refreshing(.none): nil
        }
    }
}
