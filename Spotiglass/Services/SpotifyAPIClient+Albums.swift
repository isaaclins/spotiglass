import Foundation

struct AlbumTrackFetchResult: Equatable {
    let tracks: [SpotifyTrack]
}

private struct AlbumTrackRequestKey: Hashable {
    let albumID: String
    /// Coalescer-only normalization: callers that pass `nil` or an empty market collapse onto the same key
    /// as callers that pass `from_token`, so a transient `currentUserProfile` failure cannot fan out into a
    /// second concurrent network call for the same album.
    let market: String
    let limit: Int

    init(albumID: String, market: String?, limit: Int) {
        self.albumID = albumID
        let trimmed = market?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.market = (trimmed?.isEmpty ?? true) ? "from_token" : trimmed!
        self.limit = limit
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(albumID)
        hasher.combine(market)
        hasher.combine(limit)
    }

    static func == (lhs: AlbumTrackRequestKey, rhs: AlbumTrackRequestKey) -> Bool {
        lhs.albumID == rhs.albumID && lhs.market == rhs.market && lhs.limit == rhs.limit
    }
}

actor AlbumTrackRequestCoalescer {
    private var inFlight: [AlbumTrackRequestKey: Task<AlbumTrackFetchResult, Error>] = [:]

    fileprivate func run(
        key: AlbumTrackRequestKey,
        operation: @escaping @Sendable () async throws -> AlbumTrackFetchResult
    ) async throws -> AlbumTrackFetchResult {
        if let existing = inFlight[key] {
            return try await existing.value
        }
        let task = Task {
            try await operation()
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }
}

private struct BatchedAlbumsRequestKey: Hashable {
    let normalizedIDsKey: String
    let market: String

    func hash(into hasher: inout Hasher) {
        hasher.combine(normalizedIDsKey)
        hasher.combine(market)
    }

    static func == (lhs: BatchedAlbumsRequestKey, rhs: BatchedAlbumsRequestKey) -> Bool {
        lhs.normalizedIDsKey == rhs.normalizedIDsKey && lhs.market == rhs.market
    }
}

actor BatchedAlbumsRequestCoalescer {
    private var inFlight: [BatchedAlbumsRequestKey: Task<[SpotifyBatchedAlbum], Error>] = [:]

    fileprivate func run(
        key: BatchedAlbumsRequestKey,
        operation: @escaping @Sendable () async throws -> [SpotifyBatchedAlbum]
    ) async throws -> [SpotifyBatchedAlbum] {
        if let existing = inFlight[key] {
            return try await existing.value
        }
        let task = Task {
            try await operation()
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }
}

extension SpotifyAPIClient {
    /// Tracks on an album (`GET /v1/albums/{id}/tracks`). Paginates until `next` is nil or `maxPages`
    /// is reached. Concurrent duplicate requests for the same album+market+limit are coalesced.
    func albumTracks(albumID: String, market: String?, limit: Int) async throws -> [SpotifyTrack] {
        try await albumTracks(albumID: albumID, market: market, limit: limit, maxPages: 6)
    }

    func albumTracks(albumID: String, market: String?, limit: Int, maxPages: Int) async throws -> [SpotifyTrack] {
        try await albumTracksWithMetrics(albumID: albumID, market: market, limit: limit, maxPages: maxPages).tracks
    }

    func albumTracksWithMetrics(
        albumID: String,
        market: String?,
        limit: Int = 50,
        maxPages: Int = 6
    ) async throws -> AlbumTrackFetchResult {
        guard !albumID.isEmpty else {
            throw SpotifyAPIError.invalidRequest("Album ID is required.")
        }
        let key = AlbumTrackRequestKey(albumID: albumID, market: market, limit: limit)
        return try await albumTrackRequestCoalescer.run(key: key) {
            try await self.fetchAlbumTracks(albumID: albumID, market: market, limit: limit, maxPages: maxPages)
        }
    }

    /// Single-page convenience used by the artist fallback recovery path: fetches at most one page
    /// (no `next` follow-up) so a recovery for a single album never amplifies into multiple HTTP calls.
    func albumTracksFirstPage(albumID: String, market: String?, limit: Int = 10) async throws -> [SpotifyTrack] {
        try await albumTracksWithMetrics(albumID: albumID, market: market, limit: limit, maxPages: 1).tracks
    }

    /// Several albums in one round-trip via `GET /v1/albums?ids=...`. Spotify caps each request at 20 IDs;
    /// the response embeds the first 50-track page in `tracks.items` for every resolved album, which is
    /// plenty for the artist fallback that only consumes the first 10 unique track names. Unknown IDs are
    /// returned as `null` entries by Spotify and dropped here.
    func albums(ids: [String], market: String?) async throws -> [SpotifyBatchedAlbum] {
        let normalized = Self.normalizedAlbumBatchIDs(from: ids)
        guard !normalized.payloadIDs.isEmpty else { return [] }
        guard normalized.payloadIDs.count <= 20 else {
            throw SpotifyAPIError.invalidRequest("Spotify accepts at most 20 album IDs per /v1/albums request.")
        }
        let requestKey = BatchedAlbumsRequestKey(
            normalizedIDsKey: normalized.canonicalIDsKey,
            market: Self.normalizedMarketForBatchKey(market)
        )
        return try await batchedAlbumsRequestCoalescer.run(key: requestKey) {
            try await self.fetchAlbumsSingleBatch(ids: normalized.payloadIDs, market: market)
        }
    }

    /// Stale window for `/v1/albums?ids=...` reuse on 429: when the live call is throttled, serve a
    /// previously-cached body whose TTL expired within this many seconds. Bounded so we never resurface
    /// arbitrarily old album data, but generous enough to keep the artist fallback rendering during a
    /// short throttle storm. One hour past the 600 s primary TTL is the same shape Spotify advertises
    /// for retry-after windows in dev-mode applications.
    static let batchedAlbumsStaleOnRateLimitMaxAge: TimeInterval = 3_600
}

extension SpotifyAPIClient {
    fileprivate func fetchAlbumTracks(
        albumID: String,
        market: String?,
        limit: Int,
        maxPages: Int
    ) async throws -> AlbumTrackFetchResult {
        var results: [SpotifyTrack] = []
        var nextURL: URL?
        var pagesFetched = 0
        let pageCap = max(1, maxPages)
        var seenNextURLs: Set<String> = []
        repeat {
            try Task.checkCancellation()
            let page: SpotifyPagingDTO<SpotifyTrackDTO>
            if let url = nextURL {
                page = try await send(url: url)
            } else {
                var queryItems: [URLQueryItem] = [
                    URLQueryItem(name: "limit", value: String(limit)),
                    URLQueryItem(name: "offset", value: "0"),
                ]
                if let market {
                    queryItems.append(URLQueryItem(name: "market", value: market))
                }
                page = try await send(
                    path: "/v1/albums/\(albumID)/tracks",
                    queryItems: queryItems
                )
            }
            pagesFetched += 1
            results.append(contentsOf: page.items.compactMap { $0.domainModel() })
            nextURL = page.next
            if pagesFetched >= pageCap {
                break
            }
            if let nextURL {
                let key = nextURL.absoluteString
                if seenNextURLs.contains(key) {
                    break
                }
                seenNextURLs.insert(key)
            }
        } while nextURL != nil

        return AlbumTrackFetchResult(tracks: results)
    }

    fileprivate func fetchAlbumsSingleBatch(ids: [String], market: String?) async throws -> [SpotifyBatchedAlbum] {
        guard !ids.isEmpty else { return [] }
        // Outbound URL emits the same normalized market value the coalescer/cache key use, so callers
        // that pass `nil`, `""`, or `"from_token"` all collapse onto the same cache entry.
        let queryItems: [URLQueryItem] = [
            URLQueryItem(name: "ids", value: ids.joined(separator: ",")),
            URLQueryItem(name: "market", value: Self.normalizedMarketForBatchKey(market)),
        ]
        let accessToken = try await tokenProvider.accessToken()
        let request = try makeRequest(path: "/v1/albums", queryItems: queryItems, accessToken: accessToken)
        do {
            let dto: SpotifyBatchedAlbumsResponseDTO = try await send(
                request: request,
                didRefreshAfterUnauthorized: false,
                rateLimitRetryCount: 0,
                cacheMode: .freshOnly
            )
            return dto.albums.compactMap { $0?.domainModel() }
        } catch let apiError as SpotifyAPIError {
            guard case .rateLimited = apiError else {
                throw apiError
            }
            if let cache = getResponseCache,
                let cacheKey = SpotifyGETResponseCachePolicy.normalizedCacheKey(for: request),
                let stale = cache.staleEntry(
                    forCacheKey: cacheKey,
                    maxStaleAge: Self.batchedAlbumsStaleOnRateLimitMaxAge
                ),
                let decoded = try? decoder.decode(SpotifyBatchedAlbumsResponseDTO.self, from: stale.data)
            {
                return decoded.albums.compactMap { $0?.domainModel() }
            }
            throw apiError
        }
    }

    fileprivate struct NormalizedAlbumBatchIDs {
        let payloadIDs: [String]
        let canonicalIDsKey: String
    }

    fileprivate static func normalizedAlbumBatchIDs(from ids: [String]) -> NormalizedAlbumBatchIDs {
        var payloadIDs: [String] = []
        payloadIDs.reserveCapacity(ids.count)
        var seen: Set<String> = []
        for raw in ids {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            payloadIDs.append(trimmed)
        }
        let canonicalIDs = payloadIDs.sorted()
        return NormalizedAlbumBatchIDs(
            payloadIDs: payloadIDs,
            canonicalIDsKey: canonicalIDs.joined(separator: ",")
        )
    }

    fileprivate static func normalizedMarketForBatchKey(_ market: String?) -> String {
        let trimmed = market?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? "from_token" : trimmed!
    }
}
