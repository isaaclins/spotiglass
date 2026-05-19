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
            String(localized: "app.connection.signedOut.title")
        case .signingIn:
            String(localized: "app.connection.signingIn.title")
        case .signedIn:
            String(localized: "app.connection.signedIn.title")
        case .refreshing:
            String(localized: "app.connection.refreshing.title")
        case .failed:
            String(localized: "app.connection.failed.title")
        }
    }

    var message: String {
        switch self {
        case .signedOut:
            String(localized: "app.connection.signedOut.message")
        case .signingIn:
            String(localized: "app.connection.signingIn.message")
        case let .signedIn(session):
            String(
                format: String(localized: "app.connection.signedIn.message"),
                session.expiresAt.formatted(date: .omitted, time: .shortened)
            )
        case .refreshing:
            String(localized: "app.connection.refreshing.message")
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
