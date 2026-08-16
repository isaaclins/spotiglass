import Foundation

extension PlaylistBrowserViewModel {
    /// Spotify answers a 403 with the bare HTTP reason phrase "Forbidden": untranslated, and
    /// meaningless to a listener. It is folded into the details disclosure so the localized
    /// sentence is what reaches the screen. Other cases still prefer the server text, where it
    /// is genuinely descriptive ("Invalid limit") rather than a bare reason phrase.
    static func serverDiagnostics(_ serverMessage: String?, _ details: String?) -> String? {
        let parts = [serverMessage, details]
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

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
            case let .forbidden(message, details):
                return BrowsingDisplayError(
                    title: SpotiglassL10n.string("error.browsing.accessDenied.title"),
                    message: SpotiglassL10n.string("error.browsing.accessDenied.message"),
                    canRetry: false,
                    diagnosticDetails: serverDiagnostics(message, details)
                )
            case let .rateLimited(retryAfter):
                let clause = SpotifyRateLimitDisplay.retryAfterClause(seconds: retryAfter)
                return BrowsingDisplayError(
                    title: SpotiglassL10n.string("error.browsing.rateLimited.title"),
                    message: String(format: SpotiglassL10n.string("error.browsing.rateLimited.message"), clause),
                    canRetry: true,
                    diagnosticDetails: SpotifyRateLimitDisplay.rawRetryDiagnostic(seconds: retryAfter)
                )
            case let .notFound(message):
                return BrowsingDisplayError(
                    title: SpotiglassL10n.string("error.browsing.notFound.title"),
                    message: message ?? SpotiglassL10n.string("error.browsing.notFound.message"),
                    canRetry: true
                )
            case let .network(message):
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
            case let .badRequest(message, _):
                return BrowsingDisplayError(
                    title: SpotiglassL10n.string("error.browsing.badRequest.title"),
                    message: message ?? SpotiglassL10n.string("error.browsing.badRequest.message"),
                    canRetry: false,
                    diagnosticDetails: apiError.diagnosticDetails
                )
            case let .server(_, message, _):
                return BrowsingDisplayError(
                    title: SpotiglassL10n.string("error.browsing.server.title"),
                    message: message ?? SpotiglassL10n.string("error.browsing.server.message"),
                    canRetry: true,
                    diagnosticDetails: apiError.diagnosticDetails
                )
            case let .invalidRequest(message):
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
