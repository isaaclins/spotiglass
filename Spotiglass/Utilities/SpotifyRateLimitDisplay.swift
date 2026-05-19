import Foundation

/// Shared copy for Web API 429 / `Retry-After` surfaces (browsing, queue, `SpotifyAPIError.userMessage`).
enum SpotifyRateLimitDisplay {
    /// Short clause after a full sentence and a period (no leading space), e.g. `Try again shortly.`
    static func retryAfterClause(seconds: TimeInterval?) -> String {
        guard let seconds, seconds > 0 else {
            return String(localized: "error.rateLimit.tryShortly")
        }
        if seconds >= 86_400 {
            let days = Int(seconds / 86_400)
            return String(format: String(localized: "error.rateLimit.longWait"), days)
        }
        if seconds >= 7200 {
            return String(localized: "error.rateLimit.hours")
        }
        if seconds >= 3600 {
            let h = max(1, Int(seconds / 3600))
            return String(format: String(localized: "error.rateLimit.aboutHours"), h)
        }
        if seconds >= 120 {
            let m = max(1, Int(seconds / 60))
            return String(format: String(localized: "error.rateLimit.aboutMinutes"), m)
        }
        return String(format: String(localized: "error.rateLimit.seconds"), Int(seconds))
    }

    /// Optional diagnostic line with the raw backoff hint for support.
    static func rawRetryDiagnostic(seconds: TimeInterval?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        return String(format: String(localized: "error.rateLimit.diagnostic"), Int(seconds))
    }
}
