import Foundation

enum SpotifyAPIError: Error, Equatable, LocalizedError {
    case unauthorized
    case insufficientScope(requiredScopes: [String], message: String?, details: String?)
    case forbidden(message: String?, details: String?)
    case rateLimited(retryAfter: TimeInterval?)
    case notFound(message: String?)
    /// HTTP 400 — client rejected parameters (copy-paste diagnostics when present).
    case badRequest(message: String?, details: String?)
    case server(statusCode: Int, message: String?, details: String?)
    case decoding(String)
    case network(String)
    case invalidRequest(String)

    var userMessage: String {
        switch self {
        case .unauthorized:
            return "Spotify rejected this session. Sign in again, then retry."
        case .insufficientScope(let requiredScopes, let message, _):
            return message
                ?? "Your current Spotify session is missing required permissions: \(requiredScopes.joined(separator: ", ")). Disconnect and connect again to grant access."
        case .forbidden(let message, _):
            return message ?? "Spotify denied access to this resource."
        case .rateLimited(let retryAfter):
            return "Spotify is rate limiting requests. \(SpotifyRateLimitDisplay.retryAfterClause(seconds: retryAfter))"
        case .notFound(let message):
            return message ?? "This Spotify item is unavailable or was removed."
        case .badRequest(let message, _):
            if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Spotify rejected this request: \(message)"
            }
            return "Spotify rejected this request."
        case .server(let statusCode, let message, _):
            let codeHint = "status code \(statusCode)"
            if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Spotify’s servers had a problem (\(codeHint)): \(message). Please try again in a moment."
            }
            return "Spotify’s servers had a temporary problem (\(codeHint)). Please try again in a moment."
        case .decoding(let message):
            return
                "Spotify returned playlist data in an unexpected shape. Spotiglass can now skip missing optional fields, but this response still could not be decoded. \(message)"
        case .network(let message):
            return message
        case .invalidRequest(let message):
            return message
        }
    }

    var diagnosticDetails: String? {
        switch self {
        case .insufficientScope(_, _, let details), .forbidden(_, let details), .badRequest(_, let details),
            .server(_, _, let details):
            details
        case .rateLimited(let retryAfter):
            SpotifyRateLimitDisplay.rawRetryDiagnostic(seconds: retryAfter)
        case .unauthorized, .notFound, .decoding, .network, .invalidRequest:
            nil
        }
    }

    var errorDescription: String? { userMessage }
}

struct SpotifyAPIErrorResponse: Decodable {
    let error: SpotifyAPIErrorBody
}

struct SpotifyAPIErrorBody: Decodable {
    let message: String?
}
