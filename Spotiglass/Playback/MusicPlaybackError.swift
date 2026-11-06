import Foundation

/// A playback failure in terms the session and the UI can act on, whichever service it came
/// from. Providers either throw this type (Apple Music) or throw their own errors and map them
/// here (Spotify keeps throwing `SpotifyAPIError`; ``SpotifyAPIError/playbackError`` maps it), so
/// the user-facing text always names the service that failed.
struct MusicPlaybackError: Error, Equatable, LocalizedError {
    enum Reason: Equatable {
        /// The service session expired; signing in again fixes it (Spotify: HTTP 401).
        case signInExpired
        /// The app lacks a permission it needs (Spotify: an OAuth scope; Apple Music: the
        /// system's Media & Apple Music access).
        case missingPermission
        /// The account can't play (Spotify Premium, an Apple Music subscription). `message` is
        /// the service's own text when it sent one.
        case subscriptionRequired(message: String?)
        case rateLimited(retryAfter: TimeInterval?)
        /// The request may or may not have reached the service.
        case network(String)
        /// The service failed on its side (Spotify: HTTP 5xx).
        case server
        /// The item can't be found or played.
        case notFound
        /// Anything else. The detail is for diagnostics.
        case failed
    }

    let service: MusicService
    let reason: Reason
    /// The underlying error, as text, for logs and the "command failed" message.
    let detail: String

    init(service: MusicService, reason: Reason, detail: String = "") {
        self.service = service
        self.reason = reason
        self.detail = detail
    }

    var errorDescription: String? {
        detail.isEmpty ? nil : detail
    }

    /// The neutral view of an error a playback provider threw, or `nil` when it isn't a
    /// service error (cancellation, a local error).
    static func from(_ error: Error) -> MusicPlaybackError? {
        if let error = error as? MusicPlaybackError { return error }
        if let error = error as? SpotifyAPIError { return error.playbackError }
        return nil
    }
}

extension SpotifyAPIError {
    /// How a Spotify Web API failure reads to the playback layer.
    var playbackError: MusicPlaybackError {
        let detail = String(describing: self)
        switch self {
        case .unauthorized:
            return MusicPlaybackError(service: .spotify, reason: .signInExpired, detail: detail)
        case .insufficientScope:
            return MusicPlaybackError(service: .spotify, reason: .missingPermission, detail: detail)
        case let .forbidden(message, _):
            return MusicPlaybackError(service: .spotify, reason: .subscriptionRequired(message: message), detail: detail)
        case let .rateLimited(retryAfter):
            return MusicPlaybackError(service: .spotify, reason: .rateLimited(retryAfter: retryAfter), detail: detail)
        case let .network(message):
            return MusicPlaybackError(service: .spotify, reason: .network(message), detail: detail)
        case let .server(statusCode, _, _) where statusCode >= 500:
            return MusicPlaybackError(service: .spotify, reason: .server, detail: detail)
        case .notFound:
            return MusicPlaybackError(service: .spotify, reason: .notFound, detail: detail)
        case .server, .badRequest, .decoding, .invalidRequest:
            return MusicPlaybackError(service: .spotify, reason: .failed, detail: detail)
        }
    }
}
