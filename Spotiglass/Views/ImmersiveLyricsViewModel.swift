import Combine
import Foundation

extension LrcLibClient.Failure {
    var userFacingMessage: String {
        switch self {
        case .noLyrics:
            return "No lyrics found for this track."
        case let .http(code):
            return "Lyrics service error (HTTP \(code))."
        case .decoding:
            return "Could not read lyrics from the service."
        case .invalidURL:
            return "Invalid lyrics request."
        }
    }
}

@MainActor
final class ImmersiveLyricsViewModel: ObservableObject {
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
        do {
            _ = try await fetchWithDedup(trackId: tid, track: track)
        } catch {
            // Prefetch is best-effort; failures surface when the user opens lyrics and `load` runs.
        }
    }

    func load(track: PlaybackNowPlaying) async {
        guard let tid = track.spotifyTrackIDForLyrics else {
            phase = .failed("Lyrics are only available for music tracks.")
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

        phase = .loading
        do {
            let lyrics = try await fetchWithDedup(trackId: tid, track: track)
            phase = .ready(lyrics)
        } catch let failure as LrcLibClient.Failure {
            phase = .failed(failure.userFacingMessage)
        } catch {
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
            Self.inFlight[trackId] = nil
            try? diskCache?.save(spotifyTrackID: trackId, lyrics: value)
            return value
        } catch {
            Self.inFlight[trackId] = nil
            throw error
        }
    }

    /// Clears shared in-memory state (unit tests only).
    internal static func resetSharedStateForTesting() {
        cache.removeAll()
        inFlight.removeAll()
    }
}
