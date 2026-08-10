import Foundation

struct CachedPlaylists: Codable, Equatable {
    let playlists: [SpotifyPlaylistSummary]
    let cachedAt: Date
}

struct CachedPlaylistTracks: Codable, Equatable {
    let playlistID: String
    let snapshotID: String
    let tracks: [SpotifyPlaylistTrackItem]
    let cachedAt: Date

    func isValid(forPlaylist playlistID: String, snapshotID: String, now: Date = Date(), maxAge: TimeInterval = 300)
        -> Bool
    {
        self.playlistID == playlistID && self.snapshotID == snapshotID && now.timeIntervalSince(cachedAt) <= maxAge
    }
}

private struct CachedGETResponsePayload: Codable, Equatable {
    let cachedAt: Date
    let ttlSeconds: TimeInterval
    let bodyBase64: String
}

enum SpotifyLocalCacheError: Error, Equatable {
    case applicationSupportUnavailable
}

struct SpotifyLocalCache {
    struct CachedGETResponseRecord: Equatable {
        let data: Data
        let expiresAt: Date
        let isExpired: Bool
    }

    private let rootDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager: FileManager

    init(rootDirectory: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            guard let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            else {
                throw SpotifyLocalCacheError.applicationSupportUnavailable
            }
            self.rootDirectory =
                supportDirectory
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
            cached.isValid(forPlaylist: playlistID, snapshotID: snapshotID, now: now, maxAge: maxAge)
        else {
            return nil
        }
        return cached.tracks
    }

    /// Loads cached tracks without enforcing TTL; still validates `snapshotID`
    /// to avoid showing tracks from an old playlist revision.
    func loadTracksIgnoringAge(
        playlistID: String,
        snapshotID: String
    ) throws -> [SpotifyPlaylistTrackItem]? {
        guard let cached: CachedPlaylistTracks = try read(from: tracksURL(playlistID: playlistID)),
            cached.snapshotID == snapshotID
        else {
            return nil
        }
        return cached.tracks
    }

    func invalidateTracks(playlistID: String) throws {
        try removeIfPresent(tracksURL(playlistID: playlistID))
    }

    /// Persists a successful GET response body for `SpotifyGETResponseCache` (keyed by SHA256 hex `digest`).
    func saveGETResponse(digest: String, body: Data, ttl: TimeInterval, cachedAt: Date = Date()) throws {
        let payload = CachedGETResponsePayload(
            cachedAt: cachedAt,
            ttlSeconds: ttl,
            bodyBase64: body.base64EncodedString()
        )
        try write(payload, to: getResponseURL(digest: digest))
    }

    func loadGETResponseRecord(
        digest: String,
        now: Date = Date(),
        allowExpired: Bool
    ) throws -> CachedGETResponseRecord? {
        guard let cached: CachedGETResponsePayload = try read(from: getResponseURL(digest: digest)) else {
            return nil
        }
        guard let data = Data(base64Encoded: cached.bodyBase64) else {
            return nil
        }
        let expiresAt = cached.cachedAt.addingTimeInterval(cached.ttlSeconds)
        let isExpired = expiresAt <= now
        guard allowExpired || !isExpired else {
            return nil
        }
        return CachedGETResponseRecord(data: data, expiresAt: expiresAt, isExpired: isExpired)
    }

    /// Persist the per-account pinned-items list. The file lives under
    /// `pinned/<userID>.json` so multiple Spotify accounts on the same Mac
    /// keep their pins isolated.
    func savePinnedItems(_ items: [PinnedItem], userID: String) throws {
        try write(items, to: pinnedURL(userID: userID))
    }

    func loadPinnedItems(userID: String) throws -> [PinnedItem] {
        let url = pinnedURL(userID: userID)
        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode([PinnedItem].self, from: data)
    }

    func clear() throws {
        try removeIfPresent(playlistsURL)
        try removeIfPresent(settingsURL)
        let tracksDirectory = self.tracksDirectory
        if fileManager.fileExists(atPath: tracksDirectory.path) {
            try fileManager.removeItem(at: tracksDirectory)
        }
        if fileManager.fileExists(atPath: getResponsesDirectory.path) {
            try fileManager.removeItem(at: getResponsesDirectory)
        }
        if fileManager.fileExists(atPath: pinnedDirectory.path) {
            try fileManager.removeItem(at: pinnedDirectory)
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

    private var getResponsesDirectory: URL {
        rootDirectory.appendingPathComponent("get_responses", isDirectory: true)
    }

    private var pinnedDirectory: URL {
        rootDirectory.appendingPathComponent("pinned", isDirectory: true)
    }

    private func getResponseURL(digest: String) -> URL {
        getResponsesDirectory.appendingPathComponent("\(digest).json")
    }

    private func tracksURL(playlistID: String) -> URL {
        tracksDirectory.appendingPathComponent("\(playlistID.fileSafeCacheKey).json")
    }

    private func pinnedURL(userID: String) -> URL {
        pinnedDirectory.appendingPathComponent("\(userID.fileSafeCacheKey).json")
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

extension String {
    fileprivate var fileSafeCacheKey: String {
        unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "_"
        }.joined()
    }
}
