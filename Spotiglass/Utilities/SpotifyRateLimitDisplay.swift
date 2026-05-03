import Foundation

/// Shared copy for Web API 429 / `Retry-After` surfaces (browsing, queue, `SpotifyAPIError.userMessage`).
enum SpotifyRateLimitDisplay {
    /// Short clause after a full sentence and a period (no leading space), e.g. `Try again shortly.`
    static func retryAfterClause(seconds: TimeInterval?) -> String {
        guard let seconds, seconds > 0 else {
            return "Try again shortly."
        }
        if seconds >= 86_400 {
            return "Spotify asked for a long wait (about \(Int(seconds / 86_400)) day(s)); try again later."
        }
        if seconds >= 7200 {
            return "Try again in several hours."
        }
        if seconds >= 3600 {
            let h = max(1, Int(seconds / 3600))
            return "Try again in about \(h) hour\(h == 1 ? "" : "s")."
        }
        if seconds >= 120 {
            let m = max(1, Int(seconds / 60))
            return "Try again in about \(m) minute\(m == 1 ? "" : "s")."
        }
        return "Try again in \(Int(seconds)) seconds."
    }

    /// Optional diagnostic line with the raw backoff hint for support.
    static func rawRetryDiagnostic(seconds: TimeInterval?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        return "Retry-After (seconds, as reported): \(Int(seconds))"
    }
}