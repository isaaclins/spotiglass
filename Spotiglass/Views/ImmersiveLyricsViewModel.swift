import Combine
import Foundation

extension LrcLibClient.Failure {
    var userFacingMessage: String {
        switch self {
        case .noLyrics:
            return SpotiglassL10n.string("lyrics.error.noLyrics")
        case let .rateLimited(retryAfter):
            if let retryAfter {
                return String(
                    format: SpotiglassL10n.string("lyrics.error.rateLimitedSeconds"),
                    Int(retryAfter.rounded())
                )
            }
            return SpotiglassL10n.string("lyrics.error.rateLimitedShortly")
        // The status code is a developer fact and is already in the log; the
        // reader only needs to know lyrics did not arrive (#157).
        case .http:
            return SpotiglassL10n.string("lyrics.error.http")
        case .decoding:
            return SpotiglassL10n.string("lyrics.error.decode")
        case .invalidURL:
            return SpotiglassL10n.string("lyrics.error.invalidRequest")
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
    private var loadGeneration = 0

    /// Lyrics kept in memory this session; older ones load from the disk cache again (#381).
    static let maxMemoryEntries = 200

    /// In-memory only; class is `@MainActor` so no lock is required.
    private static var cache = LRUDictionary<String, FetchedLyrics>(capacity: maxMemoryEntries)
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
        guard let tid = track.lyricsTrackKey else { return }
        guard Self.cache.value(forKey: tid) == nil else { return }
        guard !isWithinBackoffCooldown(trackId: tid) else { return }
        do {
            _ = try await fetchWithDedup(trackId: tid, track: track)
        } catch {
            // Prefetch is best-effort; failures surface when the user opens lyrics and `load` runs.
        }
    }

    func load(track: PlaybackNowPlaying) async {
        let generation = beginLoad()
        guard isCurrentLoad(generation) else { return }

        guard let tid = track.lyricsTrackKey else {
            phase = .failed(SpotiglassL10n.string("lyrics.error.musicOnly"))
            return
        }

        if let cached = Self.cache.value(forKey: tid) {
            diskCache?.markUsed(trackKey: tid)
            phase = .ready(cached)
            return
        }
        if let disk = diskCache?.load(trackKey: tid) {
            Self.cache.setValue(disk, forKey: tid)
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
            guard isCurrentLoad(generation) else { return }
            phase = .ready(lyrics)
        } catch is CancellationError {
            return
        } catch let failure as LrcLibClient.Failure {
            guard isCurrentLoad(generation) else { return }
            registerFailureBackoff(trackId: tid, failure: failure)
            phase = .failed(failure.userFacingMessage)
        } catch {
            guard isCurrentLoad(generation) else { return }
            registerFailureBackoff(trackId: tid, failure: nil)
            // localizedDescription here is an URLError or decoding dump, which
            // is not a sentence for a reader waiting on lyrics (#157).
            SpotiglassLog.error(.api, "lyrics fetch failed: \(error)")
            phase = .failed(SpotiglassL10n.string("lyrics.error.http"))
        }
    }

    private func beginLoad() -> Int {
        loadGeneration += 1
        return loadGeneration
    }

    private func isCurrentLoad(_ generation: Int) -> Bool {
        !Task.isCancelled && generation == loadGeneration
    }

    private func fetchWithDedup(trackId: String, track: PlaybackNowPlaying) async throws -> FetchedLyrics {
        if let cached = Self.cache.value(forKey: trackId) {
            return cached
        }
        if let disk = diskCache?.load(trackKey: trackId) {
            Self.cache.setValue(disk, forKey: trackId)
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
            Self.cache.setValue(value, forKey: trackId)
            Self.noLyricsCooldownUntil[trackId] = nil
            Self.backoffMetadata[trackId] = nil
            Self.inFlight[trackId] = nil
            try? diskCache?.save(trackKey: trackId, lyrics: value)
            try? diskCache?.clearTrackBackoffMetadata(trackKey: trackId)
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
        cache = LRUDictionary(capacity: maxMemoryEntries)
        inFlight.removeAll()
        noLyricsCooldownUntil.removeAll()
        backoffMetadata.removeAll()
    }

    private func isWithinBackoffCooldown(trackId: String) -> Bool {
        let now = Date()
        if let metadata = Self.backoffMetadata[trackId], metadata.nextEligibleFetchAt > now {
            return true
        }
        if let persistedMetadata = diskCache?.loadTrackBackoffMetadata(trackKey: trackId),
           persistedMetadata.nextEligibleFetchAt > now {
            Self.backoffMetadata[trackId] = persistedMetadata
            return true
        }
        if let expiry = Self.noLyricsCooldownUntil[trackId], expiry > now {
            return true
        }
        if let persisted = diskCache?.loadMissCooldownExpiry(trackKey: trackId), persisted > now {
            Self.noLyricsCooldownUntil[trackId] = persisted
            return true
        }
        return false
    }

    private func registerNoLyricsCooldown(trackId: String) {
        let now = Date()
        let expiry = now.addingTimeInterval(Self.noLyricsCooldownDuration)
        // Ended cooldowns go, the same way the disk copy drops them.
        Self.noLyricsCooldownUntil = Self.noLyricsCooldownUntil.filter { $0.value > now }
        Self.noLyricsCooldownUntil[trackId] = expiry
        try? diskCache?.saveMissCooldownExpiry(trackKey: trackId, expiresAt: expiry)
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
                return SpotiglassL10n.string("lyrics.error.unavailable")
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

        // Kept a day past its cooldown so repeated failures still back off further, like the disk copy.
        Self.backoffMetadata = Self.backoffMetadata.filter { $0.value.nextEligibleFetchAt > now.addingTimeInterval(-24 * 60 * 60) }
        Self.backoffMetadata[trackId] = metadata
        try? diskCache?.saveTrackBackoffMetadata(trackKey: trackId, metadata: metadata)
    }
}
