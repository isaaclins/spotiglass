import Foundation

enum LyricsDiskCacheError: Error, Equatable {
    case applicationSupportUnavailable
}

/// Persists LRCLIB-resolved ``FetchedLyrics`` per Spotify track id under Application Support.
struct LyricsDiskCache: Sendable {
    private let directory: URL
    private let fileManager: FileManager

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

    /// Designated for tests: writes under the given directory without touching Application Support.
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

    private func fileURL(for spotifyTrackID: String) -> URL {
        let safe = spotifyTrackID.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let name = safe.isEmpty ? "invalid" : safe
        return directory.appendingPathComponent("\(name).json")
    }
}
