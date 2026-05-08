import Foundation

extension PlaylistBrowserViewModel {
    static func displayError(for error: Error) -> BrowsingDisplayError {
        if let apiError = error as? SpotifyAPIError {
            switch apiError {
            case .unauthorized:
                return BrowsingDisplayError(title: "Sign in again", message: "Your Spotify sign-in expired. Disconnect and connect Spotify again.", canRetry: false)
            case .insufficientScope:
                return BrowsingDisplayError(
                    title: "Reconnect Spotify",
                    message: "Your current Spotify session is missing playlist or Liked Songs permissions. Disconnect and connect again to grant required scopes.",
                    canRetry: false,
                    diagnosticDetails: apiError.diagnosticDetails
                )
            case let .forbidden(message, _):
                return BrowsingDisplayError(
                    title: "Access denied",
                    message: message ?? "Spotify denied access to this resource.",
                    canRetry: false,
                    diagnosticDetails: apiError.diagnosticDetails
                )
            case let .rateLimited(retryAfter):
                let clause = SpotifyRateLimitDisplay.retryAfterClause(seconds: retryAfter)
                return BrowsingDisplayError(
                    title: "Spotify is rate limiting requests",
                    message: "Too many requests were sent to Spotify. \(clause)",
                    canRetry: true,
                    diagnosticDetails: SpotifyRateLimitDisplay.rawRetryDiagnostic(seconds: retryAfter)
                )
            case let .notFound(message):
                return BrowsingDisplayError(title: "Not found", message: message ?? "This Spotify resource is no longer available.", canRetry: true)
            case let .network(message):
                return BrowsingDisplayError(title: "Network unavailable", message: message, canRetry: true)
            case .decoding:
                return BrowsingDisplayError(title: "Could not read Spotify response", message: apiError.userMessage, canRetry: true)
            case let .badRequest(message, _):
                return BrowsingDisplayError(
                    title: "Spotify rejected the request",
                    message: message ?? "Spotify rejected this request.",
                    canRetry: false,
                    diagnosticDetails: apiError.diagnosticDetails
                )
            case let .server(_, message, _):
                return BrowsingDisplayError(
                    title: "Spotify service issue",
                    message: message ?? "Spotify returned a server error.",
                    canRetry: true,
                    diagnosticDetails: apiError.diagnosticDetails
                )
            case let .invalidRequest(message):
                return BrowsingDisplayError(title: "Invalid request", message: message, canRetry: false)
            }
        }

        return BrowsingDisplayError(title: "Something went wrong", message: error.localizedDescription, canRetry: true)
    }
}
