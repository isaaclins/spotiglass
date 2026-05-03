import CryptoKit
import Foundation

enum SpotifyGETResponseCachePolicy {
    static func normalizedCacheKey(for request: URLRequest) -> String? {
        guard request.httpMethod == nil || request.httpMethod?.uppercased() == "GET" else { return nil }
        guard let url = request.url else { return nil }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        if let items = components.queryItems, !items.isEmpty {
            let sorted = items.sorted {
                if $0.name != $1.name { return $0.name < $1.name }
                return ($0.value ?? "") < ($1.value ?? "")
            }
            components.queryItems = sorted
        }

        return components.url?.absoluteString
    }

    static func shouldCache(_ request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return ttl(for: url) != nil
    }

    static func ttl(for url: URL) -> TimeInterval? {
        let path = url.path
        if path.hasPrefix("/v1/me/playlists") { return nil }
        if path.hasPrefix("/v1/me/tracks") { return nil }
        if path.contains("/v1/playlists/") { return nil }
        if path == "/v1/me" { return 300 }
        if path.hasPrefix("/v1/search") { return 90 }
        if path.hasPrefix("/v1/artists/") { return 900 }
        if path.contains("/v1/albums/"), path.hasSuffix("/tracks") { return 600 }
        return 120
    }
}

/// TTL cache for idempotent Spotify Web API GET JSON bodies (memory + optional on-disk under `SpotifyCache/get_responses/`).
final class SpotifyGETResponseCache: @unchecked Sendable {
    static let shared: SpotifyGETResponseCache = {
        let disk = try? SpotifyLocalCache()
        return SpotifyGETResponseCache(diskCache: disk)
    }()

    private let lock = NSLock()
    private var memory: [String: (expiry: Date, data: Data)] = [:]
    private var lruKeys: [String] = []
    private let diskCache: SpotifyLocalCache?
    private let maxMemoryEntries: Int

    init(diskCache: SpotifyLocalCache?, maxMemoryEntries: Int = 160) {
        self.diskCache = diskCache
        self.maxMemoryEntries = maxMemoryEntries
    }

    func cachedBody(forCacheKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        if let entry = memory[key] {
            if entry.expiry > Date() {
                touchLRU(key)
                return entry.data
            }
            memory.removeValue(forKey: key)
            removeKeyFromLRU(key)
        }

        guard let diskCache else { return nil }
        guard let hit = try? diskCache.loadGETResponse(digest: Self.digest(for: key)) else {
            return nil
        }
        memory[key] = (expiry: hit.expiresAt, data: hit.data)
        touchLRU(key)
        return hit.data
    }

    func store(body: Data, cacheKey key: String, ttl: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }

        memory[key] = (expiry: Date().addingTimeInterval(ttl), data: body)
        touchLRU(key)
        evictMemoryIfNeeded()

        if let diskCache {
            try? diskCache.saveGETResponse(digest: Self.digest(for: key), body: body, ttl: ttl)
        }
    }

    private func touchLRU(_ key: String) {
        lruKeys.removeAll { $0 == key }
        lruKeys.append(key)
    }

    private func removeKeyFromLRU(_ key: String) {
        lruKeys.removeAll { $0 == key }
    }

    private func evictMemoryIfNeeded() {
        while memory.count > maxMemoryEntries, let first = lruKeys.first {
            lruKeys.removeFirst()
            memory.removeValue(forKey: first)
        }
    }

    private static func digest(for key: String) -> String {
        let hash = SHA256.hash(data: Data(key.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
