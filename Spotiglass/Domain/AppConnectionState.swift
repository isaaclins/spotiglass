import Foundation

// Sign-in UX state for the shell (titles/messages). Distinct from `AuthViewModel`'s
// internal flow state and from Spotify API DTOs in Services.

enum AppConnectionState: Equatable {
    case signedOut
    case signingIn
    case signedIn(AuthenticatedSession)
    case refreshing(AuthenticatedSession?)
    case failed(AuthDisplayError)
    /// The saved sign-in still works, but Spotify can't be reached right now (offline, or
    /// Spotify busy). The library stays on screen and the sign-in tries again by itself (#593).
    case paused(SpotifySignInPause)

    /// Whether a Spotify session is live: signed in, or refreshing one that exists.
    var hasSpotifySession: Bool {
        switch self {
        case .signedIn, .refreshing(.some), .paused: true
        case .signedOut, .signingIn, .failed, .refreshing(.none): false
        }
    }

    var title: String {
        switch self {
        case .signedOut:
            SpotiglassL10n.string("app.connection.signedOut.title")
        case .signingIn:
            SpotiglassL10n.string("app.connection.signingIn.title")
        case .signedIn:
            SpotiglassL10n.string("app.connection.signedIn.title")
        case .refreshing:
            SpotiglassL10n.string("app.connection.refreshing.title")
        case .failed:
            SpotiglassL10n.string("app.connection.failed.title")
        case .paused:
            SpotiglassL10n.string("app.connection.paused.title")
        }
    }

    var message: String {
        switch self {
        case .signedOut:
            SpotiglassL10n.string("app.connection.signedOut.message")
        case .signingIn:
            SpotiglassL10n.string("app.connection.signingIn.message")
        // The expiry of the access token is a developer fact: it refreshes
        // silently, so a time close to now only made people think their
        // account was about to break (#163).
        case .signedIn:
            SpotiglassL10n.string("app.connection.signedIn.message")
        case .refreshing:
            SpotiglassL10n.string("app.connection.refreshing.message")
        case let .failed(error):
            error.message
        case let .paused(pause):
            pause.message
        }
    }

    /// Whether the user has an active signed-in session or an in-flight refresh that should keep Connect disabled / Disconnect enabled.
    var isConnectedOrRefreshing: Bool {
        switch self {
        case .signedIn, .refreshing, .paused:
            true
        case .signedOut, .signingIn, .failed:
            false
        }
    }
}

/// Why a still-valid Spotify sign-in can't refresh right now, and when it tries again by itself.
struct SpotifySignInPause: Equatable {
    enum Reason: Equatable {
        /// The Mac has no network.
        case offline
        /// The network is up but Spotify didn't answer (timeout, DNS, connection refused).
        case unreachable
        /// Spotify answered 429 or 5xx.
        case busy
    }

    /// The session from before the pause, when there was one (none at a launch while offline).
    let session: AuthenticatedSession?
    let reason: Reason
    /// When the sign-in tries again by itself. `nil` means it waits for the network to come back,
    /// the Mac to wake or the next request.
    let retryAt: Date?

    var message: String {
        switch reason {
        case .offline:
            return SpotiglassL10n.string("app.connection.paused.offline")
        case .unreachable:
            return SpotiglassL10n.string("app.connection.paused.unreachable")
        case .busy:
            guard let retryAt else { return SpotiglassL10n.string("app.connection.paused.busy") }
            return SpotiglassL10n.format(
                "app.connection.paused.busyUntil",
                retryAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(SpotiglassL10n.locale))
            )
        }
    }
}

/// What a request gets while the sign-in is paused: the calm sentence, not "session expired".
struct SpotifySignInPausedError: Error, Equatable, LocalizedError {
    let pause: SpotifySignInPause
    var errorDescription: String? { pause.message }
}
