import Foundation

extension PlaylistBrowserViewModel {
    static func displayError(for error: Error) -> BrowsingDisplayError {
        if let apiError = error as? SpotifyAPIError {
            switch apiError {
            case .unauthorized:
                return BrowsingDisplayError(
                    title: SpotiglassL10n.string("error.browsing.signInAgain.title"),
                    message: SpotiglassL10n.string("error.browsing.signInAgain.message"),
                    canRetry: false
                )
            case .insufficientScope:
                return BrowsingDisplayError(
                    title: SpotiglassL10n.string("error.browsing.reconnect.title"),
                    message: SpotiglassL10n.string("error.browsing.reconnect.message"),
                    canRetry: false,
                    diagnosticDetails: apiError.diagnosticDetails
                )
            case .forbidden(let message, _):
                return BrowsingDisplayError(
                    title: SpotiglassL10n.string("error.browsing.accessDenied.title"),
                    message: message ?? SpotiglassL10n.string("error.browsing.accessDenied.message"),
                    canRetry: false,
                    diagnosticDetails: apiError.diagnosticDetails
                )
            case .rateLimited(let retryAfter):
                let clause = SpotifyRateLimitDisplay.retryAfterClause(seconds: retryAfter)
                return BrowsingDisplayError(
                    title: SpotiglassL10n.string("error.browsing.rateLimited.title"),
                    message: String(format: SpotiglassL10n.string("error.browsing.rateLimited.message"), clause),
                    canRetry: true,
                    diagnosticDetails: SpotifyRateLimitDisplay.rawRetryDiagnostic(seconds: retryAfter)
                )
            case .notFound(let message):
                return BrowsingDisplayError(
                    title: SpotiglassL10n.string("error.browsing.notFound.title"),
                    message: message ?? SpotiglassL10n.string("error.browsing.notFound.message"),
                    canRetry: true
                )
            case .network(let message):
                return BrowsingDisplayError(
                    title: SpotiglassL10n.string("error.browsing.network.title"),
                    message: message,
                    canRetry: true
                )
            case .decoding:
                return BrowsingDisplayError(
                    title: SpotiglassL10n.string("error.browsing.decoding.title"),
                    message: apiError.userMessage,
                    canRetry: true
                )
            case .badRequest(let message, _):
                return BrowsingDisplayError(
                    title: SpotiglassL10n.string("error.browsing.badRequest.title"),
                    message: message ?? SpotiglassL10n.string("error.browsing.badRequest.message"),
                    canRetry: false,
                    diagnosticDetails: apiError.diagnosticDetails
                )
            case .server(_, let message, _):
                return BrowsingDisplayError(
                    title: SpotiglassL10n.string("error.browsing.server.title"),
                    message: message ?? SpotiglassL10n.string("error.browsing.server.message"),
                    canRetry: true,
                    diagnosticDetails: apiError.diagnosticDetails
                )
            case .invalidRequest(let message):
                return BrowsingDisplayError(
                    title: SpotiglassL10n.string("error.browsing.invalidRequest.title"),
                    message: message,
                    canRetry: false
                )
            }
        }

        return BrowsingDisplayError(
            title: SpotiglassL10n.string("error.browsing.generic.title"),
            message: error.localizedDescription,
            canRetry: true
        )
    }
}
