import CryptoKit
import Foundation

enum SpotifyGETResponseCachePolicy {
    static func normalizedCacheKey(for request: URLRequest) -> String? {
        guard request.httpMethod == nil || request.httpMethod?.uppercased() == "GET" else { return nil }
        guard let url = request.url else { return nil }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        if let items = components.queryItems, !items.isEmpty {
            let mapped: [URLQueryItem]
            if components.path.hasPrefix("/v1/search") {
                mapped = items.map { item in
                    guard item.name == "q", let value = item.value else { return item }
                    return URLQueryItem(name: "q", value: Self.normalizedSearchQueryParameterValue(value))
                }
            } else if components.path == "/v1/albums" {
                mapped = items.map { item in
                    guard item.name == "ids", let value = item.value else { return item }
                    return URLQueryItem(name: "ids", value: Self.normalizedAlbumIDsParameterValue(value))
                }
            } else {
                mapped = items
            }
            let sorted = mapped.sorted {
                if $0.name != $1.name { return $0.name < $1.name }
                return ($0.value ?? "") < ($1.value ?? "")
            }
            components.queryItems = sorted
        }

        return components.url?.absoluteString
    }

    /// Lowercases and collapses whitespace so cache hits align with Spotify’s case-insensitive search semantics.
    private static func normalizedSearchQueryParameterValue(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.lowercased()
    }

    /// Canonicalizes comma-separated IDs so equivalent album sets share one cache key.
    private static func normalizedAlbumIDsParameterValue(_ raw: String) -> String {
        var deduped: [String] = []
        var seen: Set<String> = []
        for component in raw.split(separator: ",", omittingEmptySubsequences: true) {
            let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            deduped.append(trimmed)
        }
        return deduped.sorted().joined(separator: ",")
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
        // Batched album lookup (`GET /v1/albums?ids=...`) is the artist-fallback hot path; it carries
        // first-page tracks for up to 20 albums in one round-trip. Same TTL family as `/albums/{id}/tracks`.
        if path == "/v1/albums" { return 600 }
        return 120
    }
}

struct SpotifyGETCacheHit {
    let data: Data
    let isExpired: Bool
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

    func cachedEntry(forCacheKey key: String, allowExpired: Bool) -> SpotifyGETCacheHit? {
        lock.lock()
        defer { lock.unlock() }

        if let entry = memory[key] {
            let isExpired = entry.expiry <= Date()
            if allowExpired || !isExpired {
                touchLRU(key)
                return SpotifyGETCacheHit(data: entry.data, isExpired: isExpired)
            }
            // Keep the expired body in memory so `staleEntry(...)` can serve it as a stale-on-failure
            // fallback (e.g. /v1/albums on 429). LRU still bounds total memory; a successful re-fetch
            // overwrites this entry via `store(...)`.
        }

        guard let diskCache else { return nil }
        guard let hit = try? diskCache.loadGETResponseRecord(
            digest: Self.digest(for: key),
            allowExpired: allowExpired
        ) else {
            return nil
        }
        memory[key] = (expiry: hit.expiresAt, data: hit.data)
        touchLRU(key)
        return SpotifyGETCacheHit(data: hit.data, isExpired: hit.isExpired)
    }

    /// Returns an **expired** cache entry only when its age (now − expiry) is within `maxStaleAge`.
    /// Used by the API client for stale-on-failure fallback paths (e.g. serve the prior
    /// `/v1/albums?ids=...` response when the live request 429s within the stale window).
    /// Fresh entries are not returned here — they are already served by `cachedEntry(forCacheKey:allowExpired:)`
    /// in the regular send path, so the stale-only contract keeps the two call sites distinct.
    func staleEntry(forCacheKey key: String, maxStaleAge: TimeInterval) -> SpotifyGETCacheHit? {
        guard maxStaleAge > 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }

        let nowDate = Date()
        if let entry = memory[key] {
            let age = nowDate.timeIntervalSince(entry.expiry)
            if age > 0, age <= maxStaleAge {
                touchLRU(key)
                return SpotifyGETCacheHit(data: entry.data, isExpired: true)
            }
            if age > maxStaleAge {
                memory.removeValue(forKey: key)
                removeKeyFromLRU(key)
            }
        }

        guard let diskCache else { return nil }
        guard let hit = try? diskCache.loadGETResponseRecord(
            digest: Self.digest(for: key),
            allowExpired: true
        ) else {
            return nil
        }
        guard hit.isExpired else { return nil }
        let age = nowDate.timeIntervalSince(hit.expiresAt)
        guard age > 0, age <= maxStaleAge else { return nil }
        memory[key] = (expiry: hit.expiresAt, data: hit.data)
        touchLRU(key)
        return SpotifyGETCacheHit(data: hit.data, isExpired: true)
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
