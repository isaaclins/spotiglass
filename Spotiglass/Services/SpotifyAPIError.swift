import Foundation

extension String {
    /// `nil` when the string is empty or only whitespace, so a diagnostics blob
    /// assembled from optional parts collapses to "no diagnostics" rather than
    /// an empty disclosure triangle.
    var nilWhenEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

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
            return SpotiglassL10n.string("error.spotify.unauthorized")
        case .insufficientScope:
            // The scope names are developer facts and are carried in
            // diagnosticDetails; the sentence says what to do instead (#157).
            return SpotiglassL10n.string("error.spotify.insufficientPermissions")
        case .forbidden:
            // The server text here is the bare HTTP reason phrase ("Forbidden"),
            // which is not a sentence and is never translated, so the localized
            // one always wins. The server text stays in diagnosticDetails.
            return SpotiglassL10n.string("error.spotify.forbidden")
        case let .rateLimited(retryAfter):
            return SpotiglassL10n.format(
                "error.spotify.rateLimited",
                SpotifyRateLimitDisplay.retryAfterClause(seconds: retryAfter)
            )
        case let .notFound(message):
            return message ?? SpotiglassL10n.string("error.spotify.notFound")
        case let .badRequest(message, _):
            if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return SpotiglassL10n.format("error.spotify.rejectedRequest", message)
            }
            return SpotiglassL10n.string("error.spotify.rejectedRequestGeneric")
        case .server:
            // The status code and the server's own text are developer facts, so
            // they belong in diagnosticDetails rather than in the sentence the
            // listener reads (#157).
            return SpotiglassL10n.string("error.spotify.serverProblem")
        case .decoding:
            return SpotiglassL10n.string("error.spotify.unexpectedShape")
        case let .network(message):
            return message
        case let .invalidRequest(message):
            return message
        }
    }

    var diagnosticDetails: String? {
        switch self {
        case let .insufficientScope(requiredScopes, message, details):
            // Everything the message no longer says, kept where a bug report can
            // still reach it.
            [
                requiredScopes.isEmpty ? nil : "required scopes: \(requiredScopes.joined(separator: ", "))",
                message,
                details,
            ]
            .compactMap { $0 }
            .joined(separator: "\n")
            .nilWhenEmpty
        case let .forbidden(message, details):
            [message, details].compactMap { $0 }.joined(separator: "\n").nilWhenEmpty
        case let .badRequest(_, details):
            details
        case let .server(statusCode, message, details):
            ["status code \(statusCode)", message, details]
                .compactMap { $0 }
                .joined(separator: "\n")
                .nilWhenEmpty
        case let .decoding(message):
            message
        case let .rateLimited(retryAfter):
            SpotifyRateLimitDisplay.rawRetryDiagnostic(seconds: retryAfter)
        case .unauthorized, .notFound, .network, .invalidRequest:
            nil
        }
    }

    var errorDescription: String? { userMessage }

    /// The sentence a listener reads for any error a Spotify request threw. A `URLError`'s own
    /// text follows the Mac's language, not the one picked in Spotiglass, so a German window
    /// read "Could not connect to the server." (#470): transport failures get the app's own
    /// sentence instead.
    static func userMessage(for error: Error) -> String {
        if let apiError = error as? SpotifyAPIError { return apiError.userMessage }
        if let urlError = error as? URLError { return networkMessage(for: urlError) }
        // A response that didn't decode (SpotifyPlaybackAPI decodes outside the client).
        if error is DecodingError { return SpotiglassL10n.string("error.spotify.unexpectedShape") }
        return error.localizedDescription
    }

    /// A transport failure in the app's language, saying what to check.
    static func networkMessage(for error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return SpotiglassL10n.string("auth.error.offline")
        case .timedOut:
            return SpotiglassL10n.string("auth.error.timeout")
        case .cannotFindHost, .dnsLookupFailed:
            return SpotiglassL10n.string("auth.error.dns")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
             .clientCertificateRequired:
            return SpotiglassL10n.string("auth.error.tls")
        case .cancelled:
            return SpotiglassL10n.string("auth.error.cancelled")
        default:
            return SpotiglassL10n.string("auth.error.network")
        }
    }
}

struct SpotifyAPIErrorResponse: Decodable {
    let error: SpotifyAPIErrorBody
}

struct SpotifyAPIErrorBody: Decodable {
    let message: String?
}
