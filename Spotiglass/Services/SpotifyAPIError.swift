import Foundation

enum SpotifyAPIError: Error, Equatable, LocalizedError {
    case unauthorized
    case insufficientScope(requiredScopes: [String], message: String?, details: String?)
    case forbidden(message: String?, details: String?)
    case rateLimited(retryAfter: TimeInterval?)
    case notFound(message: String?)
    case server(statusCode: Int, message: String?)
    case decoding(String)
    case network(String)
    case invalidRequest(String)

    var isAuthFailure: Bool {
        if case .unauthorized = self {
            return true
        }
        return false
    }

    var userMessage: String {
        switch self {
        case .unauthorized:
            return "Spotify rejected this session. Sign in again, then retry."
        case let .insufficientScope(requiredScopes, message, _):
            return message
                ?? "Your current Spotify session is missing required permissions: \(requiredScopes.joined(separator: ", ")). Disconnect and connect again to grant access."
        case let .forbidden(message, _):
            return message ?? "Spotify denied access to this resource."
        case let .rateLimited(retryAfter):
            return retryAfter.map { "Spotify is rate limiting requests. Try again in \(Int($0)) seconds." }
                ?? "Spotify is rate limiting requests. Try again shortly."
        case let .notFound(message):
            return message ?? "This Spotify item is unavailable or was removed."
        case let .server(statusCode, message):
            let codeHint = "status code \(statusCode)"
            if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Spotify’s servers had a problem (\(codeHint)): \(message). Please try again in a moment."
            }
            return "Spotify’s servers had a temporary problem (\(codeHint)). Please try again in a moment."
        case let .decoding(message):
            return "Spotify returned playlist data in an unexpected shape. Spotiglass can now skip missing optional fields, but this response still could not be decoded. \(message)"
        case let .network(message):
            return message
        case let .invalidRequest(message):
            return message
        }
    }

    var diagnosticDetails: String? {
        switch self {
        case let .insufficientScope(_, _, details), let .forbidden(_, details):
            details
        case .unauthorized, .rateLimited, .notFound, .server, .decoding, .network, .invalidRequest:
            nil
        }
    }

    var errorDescription: String? { userMessage }
}

struct SpotifyAPIErrorResponse: Decodable {
    let error: SpotifyAPIErrorBody
}

struct SpotifyAPIErrorBody: Decodable {
    let status: Int?
    let message: String?
}
