import Foundation

enum SpotifyAPIError: Error, Equatable {
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
            "Spotify rejected this session. Sign in again, then retry."
        case let .insufficientScope(requiredScopes, message, _):
            message ?? "Your current Spotify session is missing required permissions: \(requiredScopes.joined(separator: ", ")). Disconnect and connect again to grant access."
        case let .forbidden(message, _):
            message ?? "Spotify denied access to this resource."
        case let .rateLimited(retryAfter):
            retryAfter.map { "Spotify is rate limiting requests. Try again in \(Int($0)) seconds." } ?? "Spotify is rate limiting requests. Try again shortly."
        case let .notFound(message):
            message ?? "This Spotify item is unavailable or was removed."
        case let .server(_, message):
            message ?? "Spotify returned a temporary service error."
        case let .decoding(message):
            "Spotify returned playlist data in an unexpected shape. Spotiglass can now skip missing optional fields, but this response still could not be decoded. \(message)"
        case let .network(message):
            message
        case let .invalidRequest(message):
            message
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
}

struct SpotifyAPIErrorResponse: Decodable {
    let error: SpotifyAPIErrorBody
}

struct SpotifyAPIErrorBody: Decodable {
    let status: Int?
    let message: String?
}
