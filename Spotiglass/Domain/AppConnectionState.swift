import Foundation

// Sign-in UX state for the shell (titles/messages). Distinct from `AuthViewModel`'s
// internal flow state and from Spotify API DTOs in Services.

enum AppConnectionState: Equatable {
    case signedOut
    case signingIn
    case signedIn(AuthenticatedSession)
    case refreshing(AuthenticatedSession?)
    case failed(AuthDisplayError)

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
        }
    }

    /// Whether the user has an active signed-in session or an in-flight refresh that should keep Connect disabled / Disconnect enabled.
    var isConnectedOrRefreshing: Bool {
        switch self {
        case .signedIn, .refreshing:
            true
        case .signedOut, .signingIn, .failed:
            false
        }
    }
}
