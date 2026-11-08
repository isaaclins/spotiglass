import Foundation

enum LyricsDiskCacheError: Error, Equatable {
    case applicationSupportUnavailable
}

/// Persists LRCLIB-resolved ``FetchedLyrics`` per lyrics track key (``PlaybackNowPlaying/lyricsTrackKey``) under Application Support.
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

    /// Lyrics files not read or written for this long are deleted (#381).
    static let maxAge: TimeInterval = 180 * 24 * 60 * 60
    /// Past this size the least recently used lyrics are deleted first; a song's lyrics are a
    /// few kilobytes, so this keeps several thousand songs.
    static let maxBytes: Int64 = 20 * 1024 * 1024

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

    func load(trackKey: String) -> FetchedLyrics? {
        let url = fileURL(for: trackKey)
        // Reading and marking as used are one step, so a trim either sees the song as used
        // and keeps it, or deletes it first and this read finds no file and fetches again.
        let data: Data? = DiskCacheTrim.write {
            guard let data = try? Data(contentsOf: url) else { return nil }
            _ = try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return data
        }
        guard let data else { return nil }
        return try? JSONDecoder().decode(FetchedLyrics.self, from: data)
    }

    /// Marks a song's lyrics as just used, so lyrics that keep being played are trimmed last.
    /// Showing lyrics counts, also when they came from memory.
    func markUsed(trackKey: String) {
        let path = fileURL(for: trackKey).path
        DiskCacheTrim.write { _ = try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: path) }
    }

    func save(trackKey: String, lyrics: FetchedLyrics) throws {
        let data = try JSONEncoder().encode(lyrics)
        let url = fileURL(for: trackKey)
        try DiskCacheTrim.write { try data.write(to: url, options: .atomic) }
        // Saves run on the main actor; listing the directory doesn't need to.
        let cache = self
        Task.detached(priority: .utility) { cache.prune() }
    }

    /// Deletes lyrics older than `maxAge` and, past `maxBytes`, the least recently used ones.
    /// The cooldown and backoff files bound themselves and are never deleted here.
    func prune(now: Date = Date(), maxAge: TimeInterval = LyricsDiskCache.maxAge, maxBytes: Int64 = LyricsDiskCache.maxBytes) {
        DiskCacheTrim.trim(
            directory: directory,
            maxBytes: maxBytes,
            maxAge: maxAge,
            now: now,
            keepingFileNames: [missCooldownFileName, backoffMetadataFileName],
            fileManager: fileManager
        )
    }

    func loadMissCooldownExpiry(trackKey: String) -> Date? {
        let key = normalizedTrackID(trackKey)
        guard !key.isEmpty else { return nil }
        guard let entries = loadMissCooldownEntries() else { return nil }
        return entries[key]
    }

    func saveMissCooldownExpiry(trackKey: String, expiresAt: Date) throws {
        let key = normalizedTrackID(trackKey)
        guard !key.isEmpty else { return }
        let now = Date()
        var entries = loadMissCooldownEntries() ?? [:]
        entries = entries.filter { $0.value > now }
        entries[key] = expiresAt
        let data = try JSONEncoder().encode(entries)
        try data.write(to: missCooldownFileURL, options: .atomic)
    }

    func loadTrackBackoffMetadata(trackKey: String) -> TrackBackoffMetadata? {
        let key = normalizedTrackID(trackKey)
        guard !key.isEmpty else { return nil }
        guard let map = loadBackoffMetadataEntries() else { return nil }
        return map[key]
    }

    func saveTrackBackoffMetadata(trackKey: String, metadata: TrackBackoffMetadata) throws {
        let key = normalizedTrackID(trackKey)
        guard !key.isEmpty else { return }
        var map = loadBackoffMetadataEntries() ?? [:]
        map = map.filter { $0.value.nextEligibleFetchAt > Date().addingTimeInterval(-24 * 60 * 60) }
        map[key] = metadata
        let data = try JSONEncoder().encode(map)
        try data.write(to: backoffMetadataFileURL, options: .atomic)
    }

    func clearTrackBackoffMetadata(trackKey: String) throws {
        let key = normalizedTrackID(trackKey)
        guard !key.isEmpty else { return }
        guard var map = loadBackoffMetadataEntries() else { return }
        map.removeValue(forKey: key)
        let data = try JSONEncoder().encode(map)
        try data.write(to: backoffMetadataFileURL, options: .atomic)
    }

    private func fileURL(for trackKey: String) -> URL {
        let safe = normalizedTrackID(trackKey)
        let name = safe.isEmpty ? "invalid" : safe
        return directory.appendingPathComponent("\(name).json")
    }

    private var missCooldownFileURL: URL {
        directory.appendingPathComponent(missCooldownFileName)
    }

    private var backoffMetadataFileURL: URL {
        directory.appendingPathComponent(backoffMetadataFileName)
    }

    private func normalizedTrackID(_ trackKey: String) -> String {
        trackKey.filter { $0.isLetter || $0.isNumber || $0 == "-" }
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
