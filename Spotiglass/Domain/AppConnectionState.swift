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
        case .signedIn(let session):
            String(
                format: SpotiglassL10n.string("app.connection.signedIn.message"),
                session.expiresAt.formatted(date: .omitted, time: .shortened)
            )
        case .refreshing:
            SpotiglassL10n.string("app.connection.refreshing.message")
        case .failed(let error):
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
