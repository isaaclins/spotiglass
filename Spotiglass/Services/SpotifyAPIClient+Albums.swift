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
    let maxPages: Int

    init(albumID: String, market: String?, limit: Int, maxPages: Int) {
        self.albumID = albumID
        let trimmed = market?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.market = (trimmed?.isEmpty ?? true) ? "from_token" : trimmed!
        self.limit = limit
        self.maxPages = max(1, maxPages)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(albumID)
        hasher.combine(market)
        hasher.combine(limit)
        hasher.combine(maxPages)
    }

    static func == (lhs: AlbumTrackRequestKey, rhs: AlbumTrackRequestKey) -> Bool {
        lhs.albumID == rhs.albumID && lhs.market == rhs.market && lhs.limit == rhs.limit && lhs.maxPages == rhs.maxPages
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

extension SpotifyAPIClient {
    /// Tracks on an album (`GET /v1/albums/{id}/tracks`). Paginates until `next` is nil or `maxPages`
    /// is reached. Concurrent duplicate requests for the same album+market+limit+maxPages are coalesced.
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
        let key = AlbumTrackRequestKey(albumID: albumID, market: market, limit: limit, maxPages: maxPages)
        return try await albumTrackRequestCoalescer.run(key: key) {
            try await self.fetchAlbumTracks(albumID: albumID, market: market, limit: limit, maxPages: maxPages)
        }
    }

    /// Single page used by the artist fallback. A selected album never amplifies into multiple HTTP calls.
    func albumTracksFirstPage(albumID: String, market: String?, limit: Int = 10) async throws -> [SpotifyTrack] {
        try await albumTracksWithMetrics(albumID: albumID, market: market, limit: limit, maxPages: 1).tracks
    }
}

private extension SpotifyAPIClient {
    func fetchAlbumTracks(
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
                    URLQueryItem(name: "offset", value: "0")
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
}
