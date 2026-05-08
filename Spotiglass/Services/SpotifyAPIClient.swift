import Foundation

enum SpotifyRequestCacheMode {
    case freshOnly
    case allowStale
    case bypassCache
}

struct AlbumTrackFetchResult: Equatable {
    let tracks: [SpotifyTrack]
    let pageRequests: Int
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

protocol SpotifyAccessTokenProviding {
    func accessToken() async throws -> String
    func refreshAccessTokenAfterUnauthorized() async throws -> String
}

struct StaticSpotifyAccessTokenProvider: SpotifyAccessTokenProviding {
    let token: String

    func accessToken() async throws -> String {
        token
    }

    func refreshAccessTokenAfterUnauthorized() async throws -> String {
        token
    }
}

struct SpotifyAPIClient {
    struct SpotifyArtistAlbumsPage {
        let items: [SpotifyArtistAlbum]
        let next: URL?
    }

    struct CachedResponse<Value> {
        let value: Value
        let isStale: Bool
    }

    private let baseURL: URL
    private let tokenProvider: SpotifyAccessTokenProviding
    private let httpClient: HTTPClient
    private let decoder: JSONDecoder
    private let getResponseCache: SpotifyGETResponseCache?
    private let albumTrackRequestCoalescer: AlbumTrackRequestCoalescer
    private let batchedAlbumsRequestCoalescer: BatchedAlbumsRequestCoalescer

    init(
        baseURL: URL = URL(string: "https://api.spotify.com")!,
        tokenProvider: SpotifyAccessTokenProviding,
        httpClient: HTTPClient = URLSession.shared,
        getResponseCache: SpotifyGETResponseCache? = nil,
        albumTrackRequestCoalescer: AlbumTrackRequestCoalescer = AlbumTrackRequestCoalescer(),
        batchedAlbumsRequestCoalescer: BatchedAlbumsRequestCoalescer = BatchedAlbumsRequestCoalescer()
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.httpClient = httpClient
        self.decoder = JSONDecoder.spotifyWebAPI
        self.getResponseCache = getResponseCache
        self.albumTrackRequestCoalescer = albumTrackRequestCoalescer
        self.batchedAlbumsRequestCoalescer = batchedAlbumsRequestCoalescer
    }

    func currentUserProfile() async throws -> SpotifyUserProfile {
        let dto: SpotifyUserProfileDTO = try await send(path: "/v1/me")
        return dto.domainModel()
    }

    func artist(id: String, cacheMode: SpotifyRequestCacheMode = .freshOnly) async throws -> SpotifyArtistDetail {
        guard !id.isEmpty else {
            throw SpotifyAPIError.invalidRequest("Artist ID is required.")
        }
        let dto: SpotifyArtistDetailDTO = try await send(path: "/v1/artists/\(id)", cacheMode: cacheMode)
        return dto.domainModel()
    }

    func artist(id: String) async throws -> SpotifyArtistDetail {
        try await artist(id: id, cacheMode: .freshOnly)
    }

    func artistCached(id: String, cacheMode: SpotifyRequestCacheMode = .allowStale) async throws -> CachedResponse<SpotifyArtistDetail> {
        guard !id.isEmpty else {
            throw SpotifyAPIError.invalidRequest("Artist ID is required.")
        }
        let cached: CachedResponse<SpotifyArtistDetailDTO> = try await sendCached(path: "/v1/artists/\(id)", cacheMode: cacheMode)
        return CachedResponse(value: cached.value.domainModel(), isStale: cached.isStale)
    }

    func artistTopTracks(id: String, market: String?) async throws -> [SpotifyTrack] {
        guard !id.isEmpty else {
            throw SpotifyAPIError.invalidRequest("Artist ID is required.")
        }
        let marketValue = market ?? "from_token"
        let dto: SpotifyTopTracksResponseDTO = try await send(
            path: "/v1/artists/\(id)/top-tracks",
            queryItems: [URLQueryItem(name: "market", value: marketValue)]
        )
        return dto.tracks.compactMap { $0.domainModel() }
    }

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

    private func fetchAlbumTracks(
        albumID: String,
        market: String?,
        limit: Int,
        maxPages: Int
    ) async throws -> AlbumTrackFetchResult {
        var results: [SpotifyTrack] = []
        var nextURL: URL?
        var pageRequests = 0
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
            pageRequests += 1
            results.append(contentsOf: page.items.compactMap { $0.domainModel() })
            nextURL = page.next
            if pageRequests >= pageCap {
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

        return AlbumTrackFetchResult(tracks: results, pageRequests: pageRequests)
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

    private func fetchAlbumsSingleBatch(ids: [String], market: String?) async throws -> [SpotifyBatchedAlbum] {
        guard !ids.isEmpty else { return [] }
        // Outbound URL emits the same normalized market value the coalescer/cache key use, so callers
        // that pass `nil`, `""`, or `"from_token"` all collapse onto the same cache entry.
        let queryItems: [URLQueryItem] = [
            URLQueryItem(name: "ids", value: ids.joined(separator: ",")),
            URLQueryItem(name: "market", value: Self.normalizedMarketForBatchKey(market))
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
               let decoded = try? decoder.decode(SpotifyBatchedAlbumsResponseDTO.self, from: stale.data) {
                return decoded.albums.compactMap { $0?.domainModel() }
            }
            throw apiError
        }
    }

    /// Spotify documents `GET /v1/artists/{id}/albums` with **maximum `limit` of 10**. Larger values return HTTP 400.
    /// Pagination is **capped** so opening a large discography does not issue hundreds of requests (rate limits, especially in Web API Development mode).
    func artistAlbums(
        id: String,
        includeGroups: String = "album,single,compilation,appears_on",
        limit: Int = 10,
        cacheMode: SpotifyRequestCacheMode = .freshOnly
    ) async throws -> [SpotifyArtistAlbum] {
        guard !id.isEmpty else {
            throw SpotifyAPIError.invalidRequest("Artist ID is required.")
        }
        let effectiveLimit = min(max(1, limit), 10)
        /// Upper bound on `GET /v1/artists/{id}/albums` pages per open (limit is at most 10 items per page).
        let maxPages = 20
        var results: [SpotifyArtistAlbum] = []
        var nextURL: URL?
        var pagesFetched = 0
        var seenNextURLs: Set<String> = []
        repeat {
            try Task.checkCancellation()
            let page: SpotifyPagingDTO<SpotifyArtistAlbumDTO>
            if let url = nextURL {
                let key = url.absoluteString
                if seenNextURLs.contains(key) {
                    break
                }
                seenNextURLs.insert(key)
                page = try await send(url: url, cacheMode: cacheMode)
            } else {
                page = try await send(
                    path: "/v1/artists/\(id)/albums",
                    queryItems: [
                        URLQueryItem(name: "include_groups", value: includeGroups),
                        URLQueryItem(name: "limit", value: String(effectiveLimit)),
                        URLQueryItem(name: "offset", value: "0")
                    ],
                    cacheMode: cacheMode
                )
            }
            pagesFetched += 1
            results.append(contentsOf: page.items.compactMap { $0.domainModel() })
            nextURL = page.next
            if pagesFetched >= maxPages {
                break
            }
        } while nextURL != nil

        return results
    }

    func artistAlbums(id: String, includeGroups: String = "album,single,compilation,appears_on", limit: Int = 10) async throws -> [SpotifyArtistAlbum] {
        try await artistAlbums(id: id, includeGroups: includeGroups, limit: limit, cacheMode: .freshOnly)
    }

    /// Single page from `GET /v1/artists/{id}/albums`, using either explicit
    /// offset pagination (first page) or Spotify-provided `next` URLs.
    func artistAlbumsPage(
        id: String,
        includeGroups: String = "album,single,compilation,appears_on",
        limit: Int = 10,
        offset: Int = 0,
        nextURL: URL? = nil,
        cacheMode: SpotifyRequestCacheMode = .freshOnly
    ) async throws -> SpotifyArtistAlbumsPage {
        guard !id.isEmpty else {
            throw SpotifyAPIError.invalidRequest("Artist ID is required.")
        }
        let effectiveLimit = min(max(1, limit), 10)
        let page: SpotifyPagingDTO<SpotifyArtistAlbumDTO>
        if let nextURL {
            page = try await send(url: nextURL, cacheMode: cacheMode)
        } else {
            page = try await send(
                path: "/v1/artists/\(id)/albums",
                queryItems: [
                    URLQueryItem(name: "include_groups", value: includeGroups),
                    URLQueryItem(name: "limit", value: String(effectiveLimit)),
                    URLQueryItem(name: "offset", value: String(max(0, offset)))
                ],
                cacheMode: cacheMode
            )
        }
        return SpotifyArtistAlbumsPage(
            items: page.items.compactMap { $0.domainModel() },
            next: page.next
        )
    }

    func artistAlbumsCached(
        id: String,
        includeGroups: String = "album,single,compilation,appears_on",
        limit: Int = 10,
        cacheMode: SpotifyRequestCacheMode = .allowStale
    ) async throws -> CachedResponse<[SpotifyArtistAlbum]> {
        guard !id.isEmpty else {
            throw SpotifyAPIError.invalidRequest("Artist ID is required.")
        }
        let effectiveLimit = min(max(1, limit), 10)
        let path = "/v1/artists/\(id)/albums"
        let queryItems = [
            URLQueryItem(name: "include_groups", value: includeGroups),
            URLQueryItem(name: "limit", value: String(effectiveLimit)),
            URLQueryItem(name: "offset", value: "0")
        ]
        let page: CachedResponse<SpotifyPagingDTO<SpotifyArtistAlbumDTO>> = try await sendCached(
            path: path,
            queryItems: queryItems,
            cacheMode: cacheMode
        )
        return CachedResponse(
            value: page.value.items.compactMap { $0.domainModel() },
            isStale: page.isStale
        )
    }

    func currentUserPlaylists(limit: Int = 50) async throws -> [SpotifyPlaylistSummary] {
        // `/v1/me/playlists` can span many pages; cap total pages to avoid
        // pathological loops and runaway request bursts if `next` misbehaves.
        try await collectPaged(path: "/v1/me/playlists", limit: limit, maxPages: 20) { (dto: SpotifyPlaylistDTO, _) in
            dto.domainModel()
        }
    }

    func playlistTracks(playlistID: String, limit: Int = 50, maxPages: Int = 200) async throws -> [SpotifyPlaylistTrackItem] {
        guard !playlistID.isEmpty else {
            throw SpotifyAPIError.invalidRequest("Playlist ID is required.")
        }
        let pageCap = max(1, maxPages)
        return try await collectPaged(path: "/v1/playlists/\(playlistID)/items", limit: limit, maxPages: pageCap) { (dto: SpotifyPlaylistTrackItemDTO, index) in
            dto.domainModel(position: index)
        }
    }

    /// Liked Songs (`GET /v1/me/tracks`). Paginates with the same item shape as playlist tracks; stops after `maxPages` to avoid unbounded requests.
    func currentUserSavedTracks(limit: Int = 50, maxPages: Int = 20) async throws -> SpotifySavedTracksResult {
        let pageLimit = min(max(1, limit), 50)
        let maxPages = max(1, maxPages)
        var results: [SpotifyPlaylistTrackItem] = []
        var nextURL: URL?
        var offset = 0
        var totalAvailable = 0
        var pagesFetched = 0
        var seenOffsets: Set<Int> = [offset]

        repeat {
            try Task.checkCancellation()
            let page: SpotifyPagingDTO<SpotifyPlaylistTrackItemDTO>
            if let nextURL {
                if let nextOffset = Self.offset(from: nextURL),
                   seenOffsets.contains(nextOffset) {
                    break
                }
                page = try await send(url: nextURL)
            } else {
                page = try await send(
                    path: "/v1/me/tracks",
                    queryItems: [
                        URLQueryItem(name: "limit", value: String(pageLimit)),
                        URLQueryItem(name: "offset", value: String(offset))
                    ]
                )
            }
            if pagesFetched == 0 {
                totalAvailable = page.total
            }
            let startIndex = results.count
            results.append(contentsOf: page.items.enumerated().map { index, item in
                item.domainModel(position: startIndex + index)
            })
            seenOffsets.insert(page.offset)
            nextURL = page.next
            offset += page.limit
            pagesFetched += 1
            if pagesFetched >= maxPages {
                break
            }
        } while nextURL != nil

        return SpotifySavedTracksResult(tracks: results, totalAvailable: totalAvailable)
    }

    func search(query: String, limit: Int = 6) async throws -> SpotifySearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
        }
        /// `GET /v1/search` documents `limit` range **0–10** per returned item type (not 50).
        let cappedLimit = min(max(1, limit), 10)
        let dto: SpotifySearchResponseDTO = try await send(
            path: "/v1/search",
            queryItems: [
                URLQueryItem(name: "q", value: trimmed),
                URLQueryItem(name: "type", value: "track,artist,album,playlist"),
                URLQueryItem(name: "limit", value: String(cappedLimit))
            ]
        )
        return dto.domainModel()
    }

    /// Track-only search (`GET /v1/search` with `type=track`). `limit` is capped at **10** per Spotify’s search endpoint.
    func searchTracks(query: String, limit: Int = 50) async throws -> [SpotifyTrack] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let capped = min(max(1, limit), 10)
        let dto: SpotifySearchResponseDTO = try await send(
            path: "/v1/search",
            queryItems: [
                URLQueryItem(name: "q", value: trimmed),
                URLQueryItem(name: "type", value: "track"),
                URLQueryItem(name: "limit", value: String(capped))
            ]
        )
        return dto.domainModel().tracks
    }

    func makeRequest(path: String, queryItems: [URLQueryItem] = [], accessToken: String) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), resolvingAgainstBaseURL: false) else {
            throw SpotifyAPIError.invalidRequest("Invalid Spotify API path: \(path)")
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw SpotifyAPIError.invalidRequest("Invalid Spotify API query for path: \(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func collectPaged<ItemDTO: Decodable, Domain>(
        path: String,
        limit: Int,
        maxPages: Int? = nil,
        transform: (ItemDTO, Int) -> Domain
    ) async throws -> [Domain] {
        var offset = 0
        var results: [Domain] = []
        var nextURL: URL?
        var pagesFetched = 0
        var seenNextURLs: Set<String> = []
        let pageCap = maxPages.map { max(1, $0) }

        repeat {
            try Task.checkCancellation()
            let page: SpotifyPagingDTO<ItemDTO>
            if let nextURL {
                page = try await send(url: nextURL)
            } else {
                page = try await send(
                    path: path,
                    queryItems: [
                        URLQueryItem(name: "limit", value: String(limit)),
                        URLQueryItem(name: "offset", value: String(offset))
                    ]
                )
            }

            let startIndex = results.count
            results.append(contentsOf: page.items.enumerated().map { index, item in
                transform(item, startIndex + index)
            })

            pagesFetched += 1
            if let pageCap, pagesFetched >= pageCap {
                break
            }

            nextURL = page.next
            if let nextURL {
                // Defensive loop protection: bail out if Spotify returns a
                // repeated `next` URL to prevent duplicate page storms.
                let key = nextURL.absoluteString
                if seenNextURLs.contains(key) {
                    break
                }
                seenNextURLs.insert(key)
            }
            offset += page.limit
        } while nextURL != nil

        return results
    }

    private func send<Response: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = [],
        cacheMode: SpotifyRequestCacheMode = .freshOnly
    ) async throws -> Response {
        let accessToken = try await tokenProvider.accessToken()
        let request = try makeRequest(path: path, queryItems: queryItems, accessToken: accessToken)
        return try await send(
            request: request,
            didRefreshAfterUnauthorized: false,
            rateLimitRetryCount: 0,
            cacheMode: cacheMode
        )
    }

    private func sendCached<Response: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = [],
        cacheMode: SpotifyRequestCacheMode = .allowStale
    ) async throws -> CachedResponse<Response> {
        let accessToken = try await tokenProvider.accessToken()
        let request = try makeRequest(path: path, queryItems: queryItems, accessToken: accessToken)
        return try await sendCached(
            request: request,
            didRefreshAfterUnauthorized: false,
            rateLimitRetryCount: 0,
            cacheMode: cacheMode
        )
    }

    private func send<Response: Decodable>(
        url: URL,
        cacheMode: SpotifyRequestCacheMode = .freshOnly
    ) async throws -> Response {
        let accessToken = try await tokenProvider.accessToken()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await send(
            request: request,
            didRefreshAfterUnauthorized: false,
            rateLimitRetryCount: 0,
            cacheMode: cacheMode
        )
    }

    private func sendCached<Response: Decodable>(
        request: URLRequest,
        didRefreshAfterUnauthorized: Bool,
        rateLimitRetryCount: Int,
        cacheMode: SpotifyRequestCacheMode
    ) async throws -> CachedResponse<Response> {
        if !didRefreshAfterUnauthorized,
           cacheMode != .bypassCache,
           let cache = getResponseCache,
           SpotifyGETResponseCachePolicy.shouldCache(request),
           let key = SpotifyGETResponseCachePolicy.normalizedCacheKey(for: request),
           let cacheHit = cache.cachedEntry(forCacheKey: key, allowExpired: cacheMode == .allowStale),
           let cachedValue = try? decoder.decode(Response.self, from: cacheHit.data) {
            return CachedResponse(value: cachedValue, isStale: cacheHit.isExpired)
        }

        let value: Response = try await send(
            request: request,
            didRefreshAfterUnauthorized: didRefreshAfterUnauthorized,
            rateLimitRetryCount: rateLimitRetryCount,
            cacheMode: .bypassCache
        )
        return CachedResponse(value: value, isStale: false)
    }

    private func send<Response: Decodable>(
        request: URLRequest,
        didRefreshAfterUnauthorized: Bool,
        rateLimitRetryCount: Int,
        cacheMode: SpotifyRequestCacheMode
    ) async throws -> Response {
        if !didRefreshAfterUnauthorized,
           cacheMode != .bypassCache,
           let cache = getResponseCache,
           SpotifyGETResponseCachePolicy.shouldCache(request),
           let key = SpotifyGETResponseCachePolicy.normalizedCacheKey(for: request),
           let cachedData = cache.cachedEntry(forCacheKey: key, allowExpired: cacheMode == .allowStale)?.data,
           let cachedValue = try? decoder.decode(Response.self, from: cachedData) {
            return cachedValue
        }

        do {
            let (data, response) = try await httpClient.data(for: request)
            if response.statusCode == 401 && !didRefreshAfterUnauthorized {
                let refreshedToken = try await tokenProvider.refreshAccessTokenAfterUnauthorized()
                var refreshedRequest = request
                refreshedRequest.setValue("Bearer \(refreshedToken)", forHTTPHeaderField: "Authorization")
                return try await send(
                    request: refreshedRequest,
                    didRefreshAfterUnauthorized: true,
                    rateLimitRetryCount: rateLimitRetryCount,
                    cacheMode: cacheMode
                )
            }
            guard (200..<300).contains(response.statusCode) else {
                let mappedError = mapHTTPError(
                    statusCode: response.statusCode,
                    data: data,
                    headers: response.allHeaderFields,
                    request: request
                )
                if case let .rateLimited(retryAfter) = mappedError,
                   shouldRetryAfterRateLimit(
                       request: request,
                       rateLimitRetryCount: rateLimitRetryCount,
                       retryAfter: retryAfter
                   ) {
                    try await sleepBeforeRateLimitRetry(retryAfter: retryAfter, retryCount: rateLimitRetryCount)
                    return try await send(
                        request: request,
                        didRefreshAfterUnauthorized: didRefreshAfterUnauthorized,
                        rateLimitRetryCount: rateLimitRetryCount + 1,
                        cacheMode: cacheMode
                    )
                }
                throw mappedError
            }
            do {
                let value = try decoder.decode(Response.self, from: data)
                if !didRefreshAfterUnauthorized,
                   let cache = getResponseCache,
                   SpotifyGETResponseCachePolicy.shouldCache(request),
                   let cacheKey = SpotifyGETResponseCachePolicy.normalizedCacheKey(for: request),
                   let url = request.url,
                   let ttl = SpotifyGETResponseCachePolicy.ttl(for: url) {
                    cache.store(body: data, cacheKey: cacheKey, ttl: ttl)
                }
                return value
            } catch {
                throw SpotifyAPIError.decoding(Self.describeDecodingError(error))
            }
        } catch let apiError as SpotifyAPIError {
            throw apiError
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch {
            throw SpotifyAPIError.network(error.localizedDescription)
        }
    }

    /// Inline 429 retry only fires for short `Retry-After` values. When Spotify advertises a longer
    /// cooldown we bubble `.rateLimited(retryAfter:)` up so the caller-side breakers (e.g. the
    /// per-artist batched-albums cooldown in `PlaylistBrowserViewModel`) can pause the flow without
    /// stacking extra requests inside the throttle window.
    static let inlineRateLimitRetryCeiling: TimeInterval = 8

    private func shouldRetryAfterRateLimit(
        request: URLRequest,
        rateLimitRetryCount: Int,
        retryAfter: TimeInterval?
    ) -> Bool {
        guard request.httpMethod?.uppercased() == "GET" else {
            return false
        }
        guard rateLimitRetryCount < 2 else {
            return false
        }
        if let retryAfter, retryAfter > Self.inlineRateLimitRetryCeiling {
            return false
        }
        return true
    }

    private func sleepBeforeRateLimitRetry(retryAfter: TimeInterval?, retryCount: Int) async throws {
        try Task.checkCancellation()
        let baseDelay: TimeInterval
        if let retryAfter, retryAfter > 0 {
            // `shouldRetryAfterRateLimit` already rejects values above the ceiling; the clamp here
            // is a defensive safeguard so the in-line wait can never exceed the inline retry budget.
            baseDelay = min(retryAfter, Self.inlineRateLimitRetryCeiling)
        } else {
            baseDelay = min(pow(2, Double(retryCount)), 4)
        }
        let jitter = Double.random(in: 0...0.35)
        let nanoseconds = UInt64((baseDelay + jitter) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }

    private func mapHTTPError(statusCode: Int, data: Data, headers: [AnyHashable: Any], request: URLRequest) -> SpotifyAPIError {
        let message = try? decoder.decode(SpotifyAPIErrorResponse.self, from: data).error.message
        let details = diagnosticDetails(statusCode: statusCode, data: data, headers: headers, request: request, message: message)
        switch statusCode {
        case 401:
            return .unauthorized
        case 400:
            return .badRequest(message: message, details: details)
        case 403:
            if isInsufficientScope(headers: headers, message: message) {
                return .insufficientScope(
                    requiredScopes: requiredScopes(for: request),
                    message: message,
                    details: details
                )
            }
            return .forbidden(message: message, details: details)
        case 404:
            return .notFound(message: message)
        case 429:
            return .rateLimited(retryAfter: retryAfter(from: headers))
        case 500...599:
            return .server(statusCode: statusCode, message: message, details: details)
        default:
            return .server(statusCode: statusCode, message: message, details: details)
        }
    }

    private func retryAfter(from headers: [AnyHashable: Any]) -> TimeInterval? {
        guard let raw = headerValue(named: "Retry-After", in: headers)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(raw), seconds >= 0 {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: raw) {
            return max(0, date.timeIntervalSinceNow)
        }
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        if let date = formatter.date(from: raw) {
            return max(0, date.timeIntervalSinceNow)
        }
        return nil
    }

    private func isInsufficientScope(headers: [AnyHashable: Any], message: String?) -> Bool {
        let authenticateHeader = headerValue(named: "WWW-Authenticate", in: headers)
        let combined = [authenticateHeader, message]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        return combined.contains("insufficient_scope")
            || combined.contains("playlist-read-private")
            || combined.contains("playlist-read-collaborative")
            || combined.contains("insufficient client scope")
    }

    private func headerValue(named name: String, in headers: [AnyHashable: Any]) -> String? {
        headers.first { key, _ in
            String(describing: key).caseInsensitiveCompare(name) == .orderedSame
        }?.value as? String
    }

    private func diagnosticDetails(
        statusCode: Int,
        data: Data,
        headers: [AnyHashable: Any],
        request: URLRequest,
        message: String?
    ) -> String {
        let body = String(data: data, encoding: .utf8) ?? "<non-UTF8 response body>"

        return """
        \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "<missing URL>")
        HTTP \(statusCode)

        Response headers:
        \(headers.rawHeaderDump)

        Response body:
        \(body)
        """
    }

    private func requiredScopes(for request: URLRequest) -> [String] {
        SpotifyAuthConfiguration.requiredBrowsingScopes
    }

    private static func describeDecodingError(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return error.localizedDescription
        }

        switch decodingError {
        case let .keyNotFound(key, context):
            return "Missing key '\(key.stringValue)' at \(context.codingPath.readablePath)."
        case let .valueNotFound(type, context):
            return "Missing \(type) value at \(context.codingPath.readablePath)."
        case let .typeMismatch(type, context):
            return "Expected \(type) at \(context.codingPath.readablePath): \(context.debugDescription)"
        case let .dataCorrupted(context):
            return "Invalid data at \(context.codingPath.readablePath): \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }

    private static func offset(from url: URL) -> Int? {
        guard let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let offsetValue = queryItems.first(where: { $0.name == "offset" })?.value else {
            return nil
        }
        return Int(offsetValue)
    }

    private struct NormalizedAlbumBatchIDs {
        let payloadIDs: [String]
        let canonicalIDsKey: String
    }

    private static func normalizedAlbumBatchIDs(from ids: [String]) -> NormalizedAlbumBatchIDs {
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

    private static func normalizedMarketForBatchKey(_ market: String?) -> String {
        let trimmed = market?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? "from_token" : trimmed!
    }
}

private extension JSONDecoder {
    static var spotifyWebAPI: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension Array where Element == CodingKey {
    var readablePath: String {
        guard !isEmpty else { return "response root" }
        return map(\.stringValue).joined(separator: ".")
    }
}

private extension Dictionary where Key == AnyHashable, Value == Any {
    var rawHeaderDump: String {
        guard !isEmpty else {
            return "<none>"
        }

        return map { key, value in
            "\(String(describing: key)): \(String(describing: value))"
        }
        .sorted()
        .joined(separator: "\n")
    }
}
