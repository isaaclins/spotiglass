import Combine
import Foundation

extension LrcLibClient.Failure {
    var userFacingMessage: String {
        switch self {
        case .noLyrics:
            return String(localized: "lyrics.error.noLyrics")
        case let .rateLimited(retryAfter):
            if let retryAfter {
                return String(
                    format: String(localized: "lyrics.error.rateLimitedSeconds"),
                    Int(retryAfter.rounded())
                )
            }
            return String(localized: "lyrics.error.rateLimitedShortly")
        case let .http(code):
            return String(format: String(localized: "lyrics.error.http"), code)
        case .decoding:
            return String(localized: "lyrics.error.decode")
        case .invalidURL:
            return String(localized: "lyrics.error.invalidRequest")
        }
    }
}

@MainActor
final class ImmersiveLyricsViewModel: ObservableObject {
    private static let noLyricsCooldownDuration: TimeInterval = 10 * 60
    private static let decodingCooldownDuration: TimeInterval = 5 * 60
    private static let permanentCooldownDuration: TimeInterval = 15 * 60
    private static let transientBaseCooldownDuration: TimeInterval = 30
    private static let transientMaxCooldownDuration: TimeInterval = 10 * 60
    private static let rateLimitedFallbackCooldownDuration: TimeInterval = 60

    enum Phase: Equatable {
        case idle
        case loading
        case ready(FetchedLyrics)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private let fetch: (PlaybackNowPlaying) async throws -> FetchedLyrics
    private let diskCache: LyricsDiskCache?

    /// In-memory only; class is `@MainActor` so no lock is required.
    private static var cache: [String: FetchedLyrics] = [:]
    private static var inFlight: [String: Task<FetchedLyrics, Error>] = [:]
    private static var noLyricsCooldownUntil: [String: Date] = [:]
    private static var backoffMetadata: [String: LyricsDiskCache.TrackBackoffMetadata] = [:]

    init(fetchLyrics: @escaping (PlaybackNowPlaying) async throws -> FetchedLyrics, diskCache: LyricsDiskCache? = nil) {
        self.fetch = fetchLyrics
        self.diskCache = diskCache
    }

    convenience init(client: LrcLibClient = LrcLibClient()) {
        let disk = try? LyricsDiskCache()
        self.init(fetchLyrics: { try await client.fetchLyrics(for: $0) }, diskCache: disk)
    }

    /// Fetches lyrics in the background without changing `phase` (for prefetch while the overlay is closed).
    func preload(track: PlaybackNowPlaying) async {
        guard let tid = track.spotifyTrackIDForLyrics else { return }
        guard Self.cache[tid] == nil else { return }
        guard !isWithinBackoffCooldown(trackId: tid) else { return }
        do {
            _ = try await fetchWithDedup(trackId: tid, track: track)
        } catch {
            // Prefetch is best-effort; failures surface when the user opens lyrics and `load` runs.
        }
    }

    func load(track: PlaybackNowPlaying) async {
        guard let tid = track.spotifyTrackIDForLyrics else {
            phase = .failed(String(localized: "lyrics.error.musicOnly"))
            return
        }

        if let cached = Self.cache[tid] {
            phase = .ready(cached)
            return
        }
        if let disk = diskCache?.load(spotifyTrackID: tid) {
            Self.cache[tid] = disk
            phase = .ready(disk)
            return
        }
        if isWithinBackoffCooldown(trackId: tid) {
            phase = .failed(cooldownMessage(trackId: tid))
            return
        }

        phase = .loading
        do {
            let lyrics = try await fetchWithDedup(trackId: tid, track: track)
            phase = .ready(lyrics)
        } catch let failure as LrcLibClient.Failure {
            registerFailureBackoff(trackId: tid, failure: failure)
            phase = .failed(failure.userFacingMessage)
        } catch {
            registerFailureBackoff(trackId: tid, failure: nil)
            phase = .failed(error.localizedDescription)
        }
    }

    private func fetchWithDedup(trackId: String, track: PlaybackNowPlaying) async throws -> FetchedLyrics {
        if let cached = Self.cache[trackId] {
            return cached
        }
        if let disk = diskCache?.load(spotifyTrackID: trackId) {
            Self.cache[trackId] = disk
            return disk
        }
        if let existing = Self.inFlight[trackId] {
            return try await existing.value
        }
        let newTask = Task {
            try await fetch(track)
        }
        Self.inFlight[trackId] = newTask
        do {
            let value = try await newTask.value
            Self.cache[trackId] = value
            Self.noLyricsCooldownUntil[trackId] = nil
            Self.backoffMetadata[trackId] = nil
            Self.inFlight[trackId] = nil
            try? diskCache?.save(spotifyTrackID: trackId, lyrics: value)
            try? diskCache?.clearTrackBackoffMetadata(spotifyTrackID: trackId)
            return value
        } catch {
            Self.inFlight[trackId] = nil
            throw error
        }
    }

    /// Clears shared in-memory state (`SpotiglassTests` only).
    // periphery:ignore
    internal static func resetSharedStateForTesting() {
        for task in inFlight.values {
            task.cancel()
        }
        cache.removeAll()
        inFlight.removeAll()
        noLyricsCooldownUntil.removeAll()
        backoffMetadata.removeAll()
    }

    private func isWithinBackoffCooldown(trackId: String) -> Bool {
        let now = Date()
        if let metadata = Self.backoffMetadata[trackId], metadata.nextEligibleFetchAt > now {
            return true
        }
        if let persistedMetadata = diskCache?.loadTrackBackoffMetadata(spotifyTrackID: trackId),
           persistedMetadata.nextEligibleFetchAt > now {
            Self.backoffMetadata[trackId] = persistedMetadata
            return true
        }
        if let expiry = Self.noLyricsCooldownUntil[trackId], expiry > now {
            return true
        }
        if let persisted = diskCache?.loadMissCooldownExpiry(spotifyTrackID: trackId), persisted > now {
            Self.noLyricsCooldownUntil[trackId] = persisted
            return true
        }
        return false
    }

    private func registerNoLyricsCooldown(trackId: String) {
        let expiry = Date().addingTimeInterval(Self.noLyricsCooldownDuration)
        Self.noLyricsCooldownUntil[trackId] = expiry
        try? diskCache?.saveMissCooldownExpiry(spotifyTrackID: trackId, expiresAt: expiry)
    }

    private func cooldownMessage(trackId: String) -> String {
        if let metadata = Self.backoffMetadata[trackId] {
            switch metadata.failureClass {
            case .noLyrics:
                return LrcLibClient.Failure.noLyrics.userFacingMessage
            case .decoding:
                return LrcLibClient.Failure.decoding.userFacingMessage
            case .rateLimited:
                let retryAfter = max(0, metadata.nextEligibleFetchAt.timeIntervalSinceNow)
                return LrcLibClient.Failure.rateLimited(retryAfter: retryAfter).userFacingMessage
            case .transient, .permanent:
                return String(localized: "lyrics.error.unavailable")
            }
        }
        return LrcLibClient.Failure.noLyrics.userFacingMessage
    }

    private func registerFailureBackoff(trackId: String, failure: LrcLibClient.Failure?) {
        let now = Date()
        let currentCount = Self.backoffMetadata[trackId]?.failureCount ?? 0
        let nextCount = currentCount + 1
        let metadata: LyricsDiskCache.TrackBackoffMetadata

        switch failure {
        case .noLyrics:
            registerNoLyricsCooldown(trackId: trackId)
            metadata = LyricsDiskCache.TrackBackoffMetadata(
                failureClass: .noLyrics,
                failureCount: nextCount,
                nextEligibleFetchAt: now.addingTimeInterval(Self.noLyricsCooldownDuration)
            )
        case .decoding:
            metadata = LyricsDiskCache.TrackBackoffMetadata(
                failureClass: .decoding,
                failureCount: nextCount,
                nextEligibleFetchAt: now.addingTimeInterval(Self.decodingCooldownDuration)
            )
        case let .rateLimited(retryAfter):
            let cooldown = max(Self.rateLimitedFallbackCooldownDuration, retryAfter ?? 0)
            metadata = LyricsDiskCache.TrackBackoffMetadata(
                failureClass: .rateLimited,
                failureCount: nextCount,
                nextEligibleFetchAt: now.addingTimeInterval(cooldown)
            )
        case let .http(code):
            if code >= 500 {
                let exp = min(Self.transientMaxCooldownDuration, Self.transientBaseCooldownDuration * pow(2, Double(min(nextCount, 5))))
                metadata = LyricsDiskCache.TrackBackoffMetadata(
                    failureClass: .transient,
                    failureCount: nextCount,
                    nextEligibleFetchAt: now.addingTimeInterval(exp)
                )
            } else {
                metadata = LyricsDiskCache.TrackBackoffMetadata(
                    failureClass: .permanent,
                    failureCount: nextCount,
                    nextEligibleFetchAt: now.addingTimeInterval(Self.permanentCooldownDuration)
                )
            }
        case .invalidURL, .none:
            metadata = LyricsDiskCache.TrackBackoffMetadata(
                failureClass: .permanent,
                failureCount: nextCount,
                nextEligibleFetchAt: now.addingTimeInterval(Self.permanentCooldownDuration)
            )
        }

        Self.backoffMetadata[trackId] = metadata
        try? diskCache?.saveTrackBackoffMetadata(spotifyTrackID: trackId, metadata: metadata)
    }
}
