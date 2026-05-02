import Foundation

struct CachedPlaylists: Codable, Equatable {
    let playlists: [SpotifyPlaylistSummary]
    let cachedAt: Date

    func isFresh(now: Date = Date(), maxAge: TimeInterval = 300) -> Bool {
        now.timeIntervalSince(cachedAt) <= maxAge
    }
}

struct CachedPlaylistTracks: Codable, Equatable {
    let playlistID: String
    let snapshotID: String
    let tracks: [SpotifyPlaylistTrackItem]
    let cachedAt: Date

    func isValid(for snapshotID: String, now: Date = Date(), maxAge: TimeInterval = 300) -> Bool {
        self.snapshotID == snapshotID && now.timeIntervalSince(cachedAt) <= maxAge
    }
}

struct CachedSpotifySettings: Codable, Equatable {
    var lastSelectedPlaylistID: String?
    var lastUserID: String?
}

enum SpotifyLocalCacheError: Error, Equatable {
    case applicationSupportUnavailable
}

struct SpotifyLocalCache {
    private let rootDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager: FileManager

    init(rootDirectory: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            guard let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw SpotifyLocalCacheError.applicationSupportUnavailable
            }
            self.rootDirectory = supportDirectory
                .appendingPathComponent(AppMetadata.displayName, isDirectory: true)
                .appendingPathComponent("SpotifyCache", isDirectory: true)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func savePlaylists(_ playlists: [SpotifyPlaylistSummary], cachedAt: Date = Date()) throws {
        try write(CachedPlaylists(playlists: playlists, cachedAt: cachedAt), to: playlistsURL)
    }

    func loadPlaylists(now: Date = Date(), maxAge: TimeInterval = 300) throws -> [SpotifyPlaylistSummary]? {
        guard let cached: CachedPlaylists = try read(from: playlistsURL), cached.isFresh(now: now, maxAge: maxAge) else {
            return nil
        }
        return cached.playlists
    }

    /// Read saved playlists without a TTL filter; used to decide whether to skip a redundant `me/playlists` fetch on launch.
    func loadPlaylistsBundle(now: Date = Date()) throws -> (playlists: [SpotifyPlaylistSummary], age: TimeInterval)? {
        guard let cached: CachedPlaylists = try read(from: playlistsURL) else {
            return nil
        }
        return (cached.playlists, now.timeIntervalSince(cached.cachedAt))
    }

    func saveTracks(
        _ tracks: [SpotifyPlaylistTrackItem],
        playlistID: String,
        snapshotID: String,
        cachedAt: Date = Date()
    ) throws {
        try write(
            CachedPlaylistTracks(playlistID: playlistID, snapshotID: snapshotID, tracks: tracks, cachedAt: cachedAt),
            to: tracksURL(playlistID: playlistID)
        )
    }

    func loadTracks(
        playlistID: String,
        snapshotID: String,
        now: Date = Date(),
        maxAge: TimeInterval = 300
    ) throws -> [SpotifyPlaylistTrackItem]? {
        guard let cached: CachedPlaylistTracks = try read(from: tracksURL(playlistID: playlistID)),
              cached.isValid(for: snapshotID, now: now, maxAge: maxAge) else {
            return nil
        }
        return cached.tracks
    }

    func invalidateTracks(playlistID: String) throws {
        try removeIfPresent(tracksURL(playlistID: playlistID))
    }

    func saveSettings(_ settings: CachedSpotifySettings) throws {
        try write(settings, to: settingsURL)
    }

    func loadSettings() throws -> CachedSpotifySettings {
        try read(from: settingsURL) ?? CachedSpotifySettings()
    }

    func clear() throws {
        try removeIfPresent(playlistsURL)
        try removeIfPresent(settingsURL)
        let tracksDirectory = self.tracksDirectory
        if fileManager.fileExists(atPath: tracksDirectory.path) {
            try fileManager.removeItem(at: tracksDirectory)
        }
    }

    private var playlistsURL: URL {
        rootDirectory.appendingPathComponent("playlists.json")
    }

    private var settingsURL: URL {
        rootDirectory.appendingPathComponent("settings.json")
    }

    private var tracksDirectory: URL {
        rootDirectory.appendingPathComponent("tracks", isDirectory: true)
    }

    private func tracksURL(playlistID: String) -> URL {
        tracksDirectory.appendingPathComponent("\(playlistID.fileSafeCacheKey).json")
    }

    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }

    private func read<Value: Decodable>(from url: URL) throws -> Value? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode(Value.self, from: data)
    }

    private func removeIfPresent(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try fileManager.removeItem(at: url)
    }
}

private extension String {
    var fileSafeCacheKey: String {
        unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "_"
        }.joined()
    }
}
