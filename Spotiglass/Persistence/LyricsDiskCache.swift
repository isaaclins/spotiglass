import Foundation

enum LyricsDiskCacheError: Error, Equatable {
    case applicationSupportUnavailable
}

/// Persists LRCLIB-resolved ``FetchedLyrics`` per Spotify track id under Application Support.
struct LyricsDiskCache: Sendable {
    struct TrackBackoffMetadata: Codable, Equatable, Sendable {
        enum FailureClass: String, Codable, Equatable, Sendable {
            case noLyrics
            case decoding
            case rateLimited
            case transient
            case permanent
        }

        let failureClass: FailureClass
        let failureCount: Int
        let nextEligibleFetchAt: Date
    }

    private let directory: URL
    private let fileManager: FileManager
    private let missCooldownFileName = "miss-cooldowns.json"
    private let backoffMetadataFileName = "fetch-backoff-metadata.json"

    init(fileManager: FileManager = .default) throws {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw LyricsDiskCacheError.applicationSupportUnavailable
        }
        let root = support
            .appendingPathComponent(AppMetadata.displayName, isDirectory: true)
            .appendingPathComponent("LyricsCache", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        self.directory = root
        self.fileManager = fileManager
    }

    /// Designated for tests: writes under the given directory without touching Application Support (`SpotiglassTests` only).
    // periphery:ignore
    init(directory: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        self.fileManager = fileManager
    }

    func load(spotifyTrackID: String) -> FetchedLyrics? {
        let url = fileURL(for: spotifyTrackID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FetchedLyrics.self, from: data)
    }

    func save(spotifyTrackID: String, lyrics: FetchedLyrics) throws {
        let data = try JSONEncoder().encode(lyrics)
        let url = fileURL(for: spotifyTrackID)
        try data.write(to: url, options: .atomic)
    }

    func loadMissCooldownExpiry(spotifyTrackID: String) -> Date? {
        let key = normalizedTrackID(spotifyTrackID)
        guard !key.isEmpty else { return nil }
        guard let entries = loadMissCooldownEntries() else { return nil }
        return entries[key]
    }

    func saveMissCooldownExpiry(spotifyTrackID: String, expiresAt: Date) throws {
        let key = normalizedTrackID(spotifyTrackID)
        guard !key.isEmpty else { return }
        let now = Date()
        var entries = loadMissCooldownEntries() ?? [:]
        entries = entries.filter { $0.value > now }
        entries[key] = expiresAt
        let data = try JSONEncoder().encode(entries)
        try data.write(to: missCooldownFileURL, options: .atomic)
    }

    func loadTrackBackoffMetadata(spotifyTrackID: String) -> TrackBackoffMetadata? {
        let key = normalizedTrackID(spotifyTrackID)
        guard !key.isEmpty else { return nil }
        guard let map = loadBackoffMetadataEntries() else { return nil }
        return map[key]
    }

    func saveTrackBackoffMetadata(spotifyTrackID: String, metadata: TrackBackoffMetadata) throws {
        let key = normalizedTrackID(spotifyTrackID)
        guard !key.isEmpty else { return }
        var map = loadBackoffMetadataEntries() ?? [:]
        map = map.filter { $0.value.nextEligibleFetchAt > Date().addingTimeInterval(-24 * 60 * 60) }
        map[key] = metadata
        let data = try JSONEncoder().encode(map)
        try data.write(to: backoffMetadataFileURL, options: .atomic)
    }

    func clearTrackBackoffMetadata(spotifyTrackID: String) throws {
        let key = normalizedTrackID(spotifyTrackID)
        guard !key.isEmpty else { return }
        guard var map = loadBackoffMetadataEntries() else { return }
        map.removeValue(forKey: key)
        let data = try JSONEncoder().encode(map)
        try data.write(to: backoffMetadataFileURL, options: .atomic)
    }

    private func fileURL(for spotifyTrackID: String) -> URL {
        let safe = normalizedTrackID(spotifyTrackID)
        let name = safe.isEmpty ? "invalid" : safe
        return directory.appendingPathComponent("\(name).json")
    }

    private var missCooldownFileURL: URL {
        directory.appendingPathComponent(missCooldownFileName)
    }

    private var backoffMetadataFileURL: URL {
        directory.appendingPathComponent(backoffMetadataFileName)
    }

    private func normalizedTrackID(_ spotifyTrackID: String) -> String {
        spotifyTrackID.filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    private func loadMissCooldownEntries() -> [String: Date]? {
        guard fileManager.fileExists(atPath: missCooldownFileURL.path) else { return nil }
        guard let data = try? Data(contentsOf: missCooldownFileURL) else { return nil }
        return try? JSONDecoder().decode([String: Date].self, from: data)
    }

    private func loadBackoffMetadataEntries() -> [String: TrackBackoffMetadata]? {
        guard fileManager.fileExists(atPath: backoffMetadataFileURL.path) else { return nil }
        guard let data = try? Data(contentsOf: backoffMetadataFileURL) else { return nil }
        return try? JSONDecoder().decode([String: TrackBackoffMetadata].self, from: data)
    }
}
