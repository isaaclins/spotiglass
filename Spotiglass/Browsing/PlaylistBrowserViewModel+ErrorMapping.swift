import Foundation

extension PlaylistBrowserViewModel {
    static func displayError(for error: Error) -> BrowsingDisplayError {
        if let apiError = error as? SpotifyAPIError {
            switch apiError {
            case .unauthorized:
                return BrowsingDisplayError(
                    title: String(localized: "error.browsing.signInAgain.title"),
                    message: String(localized: "error.browsing.signInAgain.message"),
                    canRetry: false
                )
            case .insufficientScope:
                return BrowsingDisplayError(
                    title: String(localized: "error.browsing.reconnect.title"),
                    message: String(localized: "error.browsing.reconnect.message"),
                    canRetry: false,
                    diagnosticDetails: apiError.diagnosticDetails
                )
            case let .forbidden(message, _):
                return BrowsingDisplayError(
                    title: String(localized: "error.browsing.accessDenied.title"),
                    message: message ?? String(localized: "error.browsing.accessDenied.message"),
                    canRetry: false,
                    diagnosticDetails: apiError.diagnosticDetails
                )
            case let .rateLimited(retryAfter):
                let clause = SpotifyRateLimitDisplay.retryAfterClause(seconds: retryAfter)
                return BrowsingDisplayError(
                    title: String(localized: "error.browsing.rateLimited.title"),
                    message: String(format: String(localized: "error.browsing.rateLimited.message"), clause),
                    canRetry: true,
                    diagnosticDetails: SpotifyRateLimitDisplay.rawRetryDiagnostic(seconds: retryAfter)
                )
            case let .notFound(message):
                return BrowsingDisplayError(
                    title: String(localized: "error.browsing.notFound.title"),
                    message: message ?? String(localized: "error.browsing.notFound.message"),
                    canRetry: true
                )
            case let .network(message):
                return BrowsingDisplayError(
                    title: String(localized: "error.browsing.network.title"),
                    message: message,
                    canRetry: true
                )
            case .decoding:
                return BrowsingDisplayError(
                    title: String(localized: "error.browsing.decoding.title"),
                    message: apiError.userMessage,
                    canRetry: true
                )
            case let .badRequest(message, _):
                return BrowsingDisplayError(
                    title: String(localized: "error.browsing.badRequest.title"),
                    message: message ?? String(localized: "error.browsing.badRequest.message"),
                    canRetry: false,
                    diagnosticDetails: apiError.diagnosticDetails
                )
            case let .server(_, message, _):
                return BrowsingDisplayError(
                    title: String(localized: "error.browsing.server.title"),
                    message: message ?? String(localized: "error.browsing.server.message"),
                    canRetry: true,
                    diagnosticDetails: apiError.diagnosticDetails
                )
            case let .invalidRequest(message):
                return BrowsingDisplayError(
                    title: String(localized: "error.browsing.invalidRequest.title"),
                    message: message,
                    canRetry: false
                )
            }
        }

        return BrowsingDisplayError(
            title: String(localized: "error.browsing.generic.title"),
            message: error.localizedDescription,
            canRetry: true
        )
    }
}
