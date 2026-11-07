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

    static func shouldCache(_ request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return ttl(for: url) != nil
    }

    static func ttl(for url: URL) -> TimeInterval? {
        let path = url.path
        // Responses below /v1/me are private to the authenticated account.
        // Do not put them in the URL-only cache, because a direct Reconnect
        // can change the account while the process and cache files survive.
        if path.hasPrefix("/v1/me") { return nil }
        if path.contains("/v1/playlists/") { return nil }
        if path.hasPrefix("/v1/search") { return 90 }
        if path.hasPrefix("/v1/artists/") { return 900 }
        if path.contains("/v1/albums/"), path.hasSuffix("/tracks") { return 600 }
        return 120
    }
}

struct SpotifyGETCacheHit {
    let data: Data
    let isExpired: Bool
}

/// Ownership token for a response write that is still current for one normalized cache key.
struct SpotifyGETResponseCacheWriteOwnership: Equatable, Sendable {
    fileprivate let cacheKey: String
    fileprivate let generation: UInt64
}

/// TTL cache for idempotent Spotify Web API GET JSON bodies (memory + optional on-disk under `SpotifyCache/get_responses/`).
final class SpotifyGETResponseCache: @unchecked Sendable {
    static let shared: SpotifyGETResponseCache = {
        let disk = try? SpotifyLocalCache()
        return SpotifyGETResponseCache(diskCache: disk)
    }()

    /// The disk directory is pruned at most this often, right after a write.
    static let diskPruneInterval: TimeInterval = 10 * 60

    private let lock = NSLock()
    private var memory: [String: (expiry: Date, data: Data)] = [:]
    private var lruKeys: [String] = []
    private var nextWriteGeneration: UInt64 = 0
    /// Requests whose response may still be stored. An entry ends when its response is stored;
    /// requests that never store one (failures, cancellations) are dropped oldest first past
    /// `maxPendingWrites`, which only costs that late response its cache write (#381).
    private var currentWriteGenerationByKey: [String: UInt64] = [:]
    private let diskCache: SpotifyLocalCache?
    private let maxMemoryEntries: Int
    private let maxPendingWrites: Int
    private let now: @Sendable () -> Date
    private var lastDiskPrune: Date?

    init(
        diskCache: SpotifyLocalCache?,
        maxMemoryEntries: Int = 160,
        maxPendingWrites: Int = 256,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.diskCache = diskCache
        self.maxMemoryEntries = maxMemoryEntries
        self.maxPendingWrites = max(1, maxPendingWrites)
        self.now = now
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
            // Keep the expired body in memory so a later `allowExpired` read can
            // serve it as a stale-on-failure fallback. LRU still bounds total
            // memory; a successful re-fetch overwrites this entry via `store(...)`.
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

    func beginWrite(forCacheKey key: String) -> SpotifyGETResponseCacheWriteOwnership {
        lock.lock()
        defer { lock.unlock() }

        nextWriteGeneration &+= 1
        currentWriteGenerationByKey[key] = nextWriteGeneration
        evictPendingWritesIfNeeded()
        return SpotifyGETResponseCacheWriteOwnership(cacheKey: key, generation: nextWriteGeneration)
    }

    @discardableResult
    func store(
        body: Data,
        cacheKey key: String,
        ttl: TimeInterval,
        ownership: SpotifyGETResponseCacheWriteOwnership
    ) -> Bool {
        lock.lock()
        guard ownership.cacheKey == key,
              currentWriteGenerationByKey[key] == ownership.generation else {
            lock.unlock()
            return false
        }
        currentWriteGenerationByKey[key] = nil
        storeLocked(body: body, cacheKey: key, ttl: ttl)
        let pruneDisk = diskPruneIsDueLocked()
        lock.unlock()

        if pruneDisk {
            diskCache?.pruneGETResponses(now: now())
        }
        return true
    }

    private func storeLocked(body: Data, cacheKey key: String, ttl: TimeInterval) {
        memory[key] = (expiry: Date().addingTimeInterval(ttl), data: body)
        touchLRU(key)
        evictMemoryIfNeeded()

        if let diskCache {
            try? diskCache.saveGETResponse(digest: Self.digest(for: key), body: body, ttl: ttl)
        }
    }

    /// True for the first disk write and then once per `diskPruneInterval`.
    private func diskPruneIsDueLocked() -> Bool {
        guard diskCache != nil else { return false }
        let current = now()
        if let lastDiskPrune, current.timeIntervalSince(lastDiskPrune) < Self.diskPruneInterval {
            return false
        }
        lastDiskPrune = current
        return true
    }

    private func evictPendingWritesIfNeeded() {
        guard currentWriteGenerationByKey.count > maxPendingWrites else { return }
        let keep = max(1, maxPendingWrites * 3 / 4)
        let oldest = currentWriteGenerationByKey
            .sorted { $0.value < $1.value }
            .prefix(currentWriteGenerationByKey.count - keep)
        for entry in oldest {
            currentWriteGenerationByKey.removeValue(forKey: entry.key)
        }
    }

    /// How many requests may still store a response (`SpotiglassTests` only).
    // periphery:ignore
    var pendingWriteCountForTesting: Int {
        lock.withLock { currentWriteGenerationByKey.count }
    }

    private func touchLRU(_ key: String) {
        lruKeys.removeAll { $0 == key }
        lruKeys.append(key)
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
