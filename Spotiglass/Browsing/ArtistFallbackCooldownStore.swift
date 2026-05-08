import Foundation

struct ArtistTopTracksProbeKey: Hashable {
    let artistID: String
    let market: String

    init(artistID: String, market: String?) {
        self.artistID = artistID
        self.market = market ?? "from_token"
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(artistID)
        hasher.combine(market)
    }

    static func == (lhs: ArtistTopTracksProbeKey, rhs: ArtistTopTracksProbeKey) -> Bool {
        lhs.artistID == rhs.artistID && lhs.market == rhs.market
    }
}

enum ArtistTopTracksProbeState {
    case forbidden(until: Date)
    case rateLimited(until: Date)
}

enum AlbumFallbackBudgetMode: Equatable {
    /// Top-tracks succeeded or returned a non-429 error; full fallback budget available.
    case healthy
    /// Short rate-limit retry-after; album fallback runs with reduced ID/recovery budget.
    case rateLimitedReduced
    /// Long rate-limit retry-after; skip album fallback entirely to avoid stacking on the back-off window.
    case skipped
}

struct ArtistAlbumFallbackStrategy {
    /// Number of album IDs sent to the batched `GET /v1/albums?ids=...` call.
    let maxAlbumRequests: Int
    /// Hard ceiling on follow-up single-album recovery `/v1/albums/{id}/tracks` calls (0 or 1).
    let maxRecoveryCalls: Int

    init(rateLimited: Bool) {
        if rateLimited {
            self.maxAlbumRequests = 3
            self.maxRecoveryCalls = 0
        } else {
            self.maxAlbumRequests = 6
            self.maxRecoveryCalls = 1
        }
    }
}

/// Endpoint breakers and recovery bookkeeping for artist top-tracks / batched album fallback.
@MainActor
final class ArtistFallbackCooldownStore {
    private var topTracksProbeState: [ArtistTopTracksProbeKey: ArtistTopTracksProbeState] = [:]
    private var batchedAlbumsCooldownUntil: [ArtistTopTracksProbeKey: Date] = [:]
    private var failedAlbumBatchCooldownUntil: [String: Date] = [:]
    private var attemptedAlbumRecoveryIDs: Set<String> = []

    func reset() {
        topTracksProbeState = [:]
        batchedAlbumsCooldownUntil = [:]
        failedAlbumBatchCooldownUntil = [:]
        attemptedAlbumRecoveryIDs = []
    }

    func shouldProbeTopTracks(for key: ArtistTopTracksProbeKey, now: Date) -> Bool {
        guard let state = topTracksProbeState[key] else {
            return true
        }
        switch state {
        case let .forbidden(until), let .rateLimited(until):
            if until > now {
                return false
            }
            topTracksProbeState[key] = nil
            return true
        }
    }

    func registerTopTracksProbeSuccess(for key: ArtistTopTracksProbeKey) {
        topTracksProbeState[key] = nil
    }

    /// Records the probe failure state and returns the budget mode the album fallback should run under.
    /// Long-retry 429s map to `.skipped` so the album fallback short-circuits instead of stacking another
    /// outbound call onto an active back-off window.
    @discardableResult
    func registerTopTracksProbeFailure(_ error: Error, for key: ArtistTopTracksProbeKey, now: Date) -> AlbumFallbackBudgetMode {
        guard let apiError = error as? SpotifyAPIError else {
            return .healthy
        }
        switch apiError {
        case .forbidden, .insufficientScope:
            topTracksProbeState[key] = .forbidden(until: now.addingTimeInterval(6 * 60 * 60))
            return .healthy
        case let .rateLimited(retryAfter):
            let cooldown = min(max(retryAfter ?? 12, 6), 60)
            topTracksProbeState[key] = .rateLimited(until: now.addingTimeInterval(cooldown))
            // Longer Retry-After values mean Spotify is actively throttling us; skipping the album fallback
            // here prevents `/v1/albums?ids=` from inheriting the same cooldown and burning the next slot.
            if let retryAfter, retryAfter > 5 {
                return .skipped
            }
            return .rateLimitedReduced
        case .unauthorized, .notFound, .badRequest, .server, .decoding, .network, .invalidRequest:
            return .healthy
        }
    }

    func shouldSkipBatchedAlbumsFallback(for key: ArtistTopTracksProbeKey, now: Date) -> Bool {
        guard let until = batchedAlbumsCooldownUntil[key] else {
            return false
        }
        if until > now {
            return true
        }
        batchedAlbumsCooldownUntil[key] = nil
        return false
    }

    func shouldSkipFailedAlbumBatch(signature: String, now: Date) -> Bool {
        guard let until = failedAlbumBatchCooldownUntil[signature] else {
            return false
        }
        if until > now {
            return true
        }
        failedAlbumBatchCooldownUntil[signature] = nil
        return false
    }

    @discardableResult
    func registerBatchedAlbumsRateLimit(for key: ArtistTopTracksProbeKey, retryAfter: TimeInterval?, now: Date) -> Date {
        let cooldown = min(max(retryAfter ?? 12, 6), 300)
        let until = now.addingTimeInterval(cooldown)
        batchedAlbumsCooldownUntil[key] = until
        return until
    }

    func recordFailedAlbumBatchCooldown(signature: String, until: Date) {
        failedAlbumBatchCooldownUntil[signature] = until
    }

    func hasAttemptedAlbumRecovery(albumID: String) -> Bool {
        attemptedAlbumRecoveryIDs.contains(albumID)
    }

    func markAlbumRecoveryAttempted(albumID: String) {
        attemptedAlbumRecoveryIDs.insert(albumID)
    }
}
