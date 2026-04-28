import Foundation

enum AppConnectionState: Equatable {
    case signedOut
    case signingIn
    case signedIn(AuthenticatedSession)
    case refreshing(AuthenticatedSession?)
    case failed(AuthDisplayError)

    var title: String {
        switch self {
        case .signedOut:
            "Spotify is not connected"
        case .signingIn:
            "Opening Spotify sign-in"
        case .signedIn:
            "Spotify is connected"
        case .refreshing:
            "Refreshing Spotify session"
        case .failed:
            "Spotify sign-in needs attention"
        }
    }

    var message: String {
        switch self {
        case .signedOut:
            "Enter your Spotify client ID, then connect your Spotify account."
        case .signingIn:
            "Complete authorization in the browser window. Spotiglass is listening on 127.0.0.1 for the callback."
        case let .signedIn(session):
            "Access token is valid until \(session.expiresAt.formatted(date: .omitted, time: .shortened))."
        case .refreshing:
            "Spotiglass is refreshing the stored Spotify session."
        case let .failed(error):
            error.message
        }
    }
}
