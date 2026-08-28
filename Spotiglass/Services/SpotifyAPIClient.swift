import Foundation

enum SpotifyRequestCacheMode: Equatable {
    case freshOnly
    case allowStale
    case bypassCache
}

protocol SpotifyAccessTokenProviding {
    func accessToken() async throws -> String
    func refreshAccessTokenAfterUnauthorized() async throws -> String
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
    let tokenProvider: SpotifyAccessTokenProviding
    let httpClient: HTTPClient
    let decoder: JSONDecoder
    let getResponseCache: SpotifyGETResponseCache?
    let albumTrackRequestCoalescer: AlbumTrackRequestCoalescer
    /// Scope information is supplied by the live auth model. Lightweight
    /// token-only clients (including catalog test doubles) leave this nil and
    /// retain their existing behavior.
    let scopeProvider: (any SpotifyScopeProviding)?

    init(
        baseURL: URL = URL(string: "https://api.spotify.com")!,
        tokenProvider: SpotifyAccessTokenProviding,
        httpClient: HTTPClient = URLSession.shared,
        getResponseCache: SpotifyGETResponseCache? = nil,
        albumTrackRequestCoalescer: AlbumTrackRequestCoalescer = AlbumTrackRequestCoalescer(),
        scopeProvider: (any SpotifyScopeProviding)? = nil
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.httpClient = httpClient
        self.decoder = JSONDecoder.spotifyWebAPI
        self.getResponseCache = getResponseCache
        self.albumTrackRequestCoalescer = albumTrackRequestCoalescer
        self.scopeProvider = scopeProvider ?? (tokenProvider as? any SpotifyScopeProviding)
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

    func collectPaged<ItemDTO: Decodable, Domain>(
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

    func send<Response: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = [],
        cacheMode: SpotifyRequestCacheMode = .freshOnly
    ) async throws -> Response {
        let traceSearch = path.hasPrefix("/v1/search")
        let tokenStart = Date()
        var request: URLRequest?
        let operationStart = Date()
        do {
            let accessToken = try await tokenProvider.accessToken()
            let tokenMs = Int(Date().timeIntervalSince(tokenStart) * 1000)
            request = try makeRequest(path: path, queryItems: queryItems, accessToken: accessToken)
            let result: Response = try await send(
                request: request!,
                didRefreshAfterUnauthorized: false,
                rateLimitRetryCount: 0,
                cacheMode: cacheMode
            )
            if traceSearch {
                SpotiglassLog.info(.api, "GET \(path) token=\(tokenMs)ms net=\(Int(Date().timeIntervalSince(operationStart) * 1000))ms")
            }
            return result
        } catch {
            logRequestFailure(request: request, method: "GET", fallbackPath: path, error: error)
            if traceSearch {
                SpotiglassLog.info(.api, "GET \(path) net=\(Int(Date().timeIntervalSince(operationStart) * 1000))ms error")
            }
            throw error
        }
    }

    func sendCached<Response: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = [],
        cacheMode: SpotifyRequestCacheMode = .allowStale
    ) async throws -> CachedResponse<Response> {
        var request: URLRequest?
        do {
            let accessToken = try await tokenProvider.accessToken()
            request = try makeRequest(path: path, queryItems: queryItems, accessToken: accessToken)
            return try await sendCached(
                request: request!,
                didRefreshAfterUnauthorized: false,
                rateLimitRetryCount: 0,
                cacheMode: cacheMode
            )
        } catch {
            logRequestFailure(request: request, method: "GET", fallbackPath: path, error: error)
            throw error
        }
    }

    func send<Response: Decodable>(
        url: URL,
        cacheMode: SpotifyRequestCacheMode = .freshOnly
    ) async throws -> Response {
        var request: URLRequest?
        do {
            let accessToken = try await tokenProvider.accessToken()
            var builtRequest = URLRequest(url: url)
            builtRequest.httpMethod = "GET"
            builtRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            builtRequest.setValue("application/json", forHTTPHeaderField: "Accept")
            request = builtRequest
            return try await send(
                request: builtRequest,
                didRefreshAfterUnauthorized: false,
                rateLimitRetryCount: 0,
                cacheMode: cacheMode
            )
        } catch {
            logRequestFailure(request: request, method: "GET", fallbackPath: url.path, error: error)
            throw error
        }
    }

    func sendCached<Response: Decodable>(
        request: URLRequest,
        didRefreshAfterUnauthorized: Bool,
        rateLimitRetryCount: Int,
        cacheMode: SpotifyRequestCacheMode
    ) async throws -> CachedResponse<Response> {
        try await enforceScopeRequirement(for: request)
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

    func send<Response: Decodable>(
        request: URLRequest,
        didRefreshAfterUnauthorized: Bool,
        rateLimitRetryCount: Int,
        cacheMode: SpotifyRequestCacheMode,
        cacheWriteOwnership: SpotifyGETResponseCacheWriteOwnership? = nil
    ) async throws -> Response {
        try await enforceScopeRequirement(for: request)
        if !didRefreshAfterUnauthorized,
           cacheMode != .bypassCache,
           let cache = getResponseCache,
           SpotifyGETResponseCachePolicy.shouldCache(request),
           let key = SpotifyGETResponseCachePolicy.normalizedCacheKey(for: request),
           let cachedData = cache.cachedEntry(forCacheKey: key, allowExpired: cacheMode == .allowStale)?.data,
           let cachedValue = try? decoder.decode(Response.self, from: cachedData) {
            return cachedValue
        }

        let writeOwnership = cacheWriteOwnership ?? beginCacheWriteOwnership(
            for: request,
            didRefreshAfterUnauthorized: didRefreshAfterUnauthorized
        )

        do {
            let (data, response) = try await httpClient.data(for: request)
            if !(200..<300).contains(response.statusCode) {
                let responseDetails = diagnosticDetails(
                    statusCode: response.statusCode,
                    data: data,
                    headers: response.allHeaderFields,
                    request: request
                )
                let message = "Spotify API failure: \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "<missing URL>")\n\(responseDetails)"
                if response.statusCode == 401 && !didRefreshAfterUnauthorized {
                    // Keep the first unauthorized response off the refresh
                    // actor's critical path. The refresh provider is the
                    // single-flight boundary, and synchronous OS logging here
                    // can let a concurrent 401 arrive after that flight ends.
                    DispatchQueue.global(qos: .utility).async {
                        SpotiglassLog.error(.api, message)
                    }
                } else {
                    SpotiglassLog.error(.api, message)
                }
            }
            if response.statusCode == 401 && !didRefreshAfterUnauthorized {
                let refreshedToken = try await tokenProvider.refreshAccessTokenAfterUnauthorized()
                var refreshedRequest = request
                refreshedRequest.setValue("Bearer \(refreshedToken)", forHTTPHeaderField: "Authorization")
                return try await send(
                    request: refreshedRequest,
                    didRefreshAfterUnauthorized: true,
                    rateLimitRetryCount: rateLimitRetryCount,
                    cacheMode: cacheMode,
                    cacheWriteOwnership: writeOwnership
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
                        cacheMode: cacheMode,
                        cacheWriteOwnership: writeOwnership
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
                   let ttl = SpotifyGETResponseCachePolicy.ttl(for: url),
                   let writeOwnership {
                    cache.store(body: data, cacheKey: cacheKey, ttl: ttl, ownership: writeOwnership)
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

    private func beginCacheWriteOwnership(
        for request: URLRequest,
        didRefreshAfterUnauthorized: Bool
    ) -> SpotifyGETResponseCacheWriteOwnership? {
        guard !didRefreshAfterUnauthorized,
              let cache = getResponseCache,
              SpotifyGETResponseCachePolicy.shouldCache(request),
              let key = SpotifyGETResponseCachePolicy.normalizedCacheKey(for: request) else {
            return nil
        }
        return cache.beginWrite(forCacheKey: key)
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

    func mapHTTPError(statusCode: Int, data: Data, headers: [AnyHashable: Any], request: URLRequest) -> SpotifyAPIError {
        let message = try? decoder.decode(SpotifyAPIErrorResponse.self, from: data).error.message
        let details = diagnosticDetails(statusCode: statusCode, data: data, headers: headers, request: request)
        switch statusCode {
        case 401:
            return .unauthorized
        case 400:
            return .badRequest(message: message, details: details)
        case 403:
            let requiredScopes = requiredScopes(for: request)
            let knownScopeRequirement = scopeRequirement(for: request)
            // Spotify does not consistently send `insufficient_scope` for
            // user-library mutations. A known user-scoped endpoint is enough
            // to classify the denial as a missing permission, while unknown
            // 403s retain the generic forbidden case.
            if isInsufficientScope(headers: headers, message: message) || !knownScopeRequirement.isEmpty {
                return .insufficientScope(
                    requiredScopes: requiredScopes,
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
        request: URLRequest
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
        let listed = scopeRequirement(for: request).listedScopes
        guard listed.isEmpty,
              request.httpMethod?.uppercased() == "GET",
              request.url?.path.hasPrefix("/v1/playlists/") == true else {
            return listed
        }
        // Keep the read capability in explicit `insufficient_scope` diagnostics
        // without preflighting followed/public playlist reads (whose 403 has a
        // separate locked-playlist meaning).
        return SpotifyAuthConfiguration.requiredPlaylistReadScopes
    }

    /// Classifies the OAuth capability needed by an endpoint. The mapping is
    /// deliberately endpoint-based so a 403 remains diagnosable even when
    /// Spotify omits the `WWW-Authenticate` scope hint.
    func scopeRequirement(for request: URLRequest) -> SpotifyScopeRequirement {
        let path = request.url?.path ?? ""
        let method = (request.httpMethod ?? "GET").uppercased()

        if path == "/v1/me/playlists" {
            if method == "GET" {
                return SpotifyScopeRequirement(allOf: SpotifyAuthConfiguration.requiredPlaylistReadScopes)
            }
            if method == "POST" {
                let isPublic = request.httpBody
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["public"] as? Bool
                return SpotifyScopeRequirement(
                    allOf: [isPublic == true
                        ? SpotifyAuthConfiguration.requiredPlaylistModifyScopes[1]
                        : SpotifyAuthConfiguration.requiredPlaylistModifyScopes[0]]
                )
            }
        }

        if path == "/v1/me/tracks" {
            return SpotifyScopeRequirement(
                allOf: method == "GET"
                    ? SpotifyAuthConfiguration.requiredSavedTracksReadScopes
                    : SpotifyAuthConfiguration.requiredSavedTracksModifyScopes
            )
        }
        if path == "/v1/me/tracks/contains" && method == "GET" {
            return SpotifyScopeRequirement(allOf: SpotifyAuthConfiguration.requiredSavedTracksReadScopes)
        }
        if path == "/v1/me/following" && method == "GET" {
            return SpotifyScopeRequirement(allOf: SpotifyAuthConfiguration.requiredFollowReadScopes)
        }
        if path == "/v1/me/player/recently-played" && method == "GET" {
            return SpotifyScopeRequirement(allOf: SpotifyAuthConfiguration.requiredRecentlyPlayedScopes)
        }
        if path.hasPrefix("/v1/me/top/") && method == "GET" {
            return SpotifyScopeRequirement(allOf: SpotifyAuthConfiguration.requiredTopReadScopes)
        }
        if path == "/v1/me/player" || path == "/v1/me/player/devices" || path == "/v1/me/player/queue" {
            return SpotifyScopeRequirement(
                allOf: method == "GET"
                    ? SpotifyAuthConfiguration.requiredPlaybackReadScopes
                    : SpotifyAuthConfiguration.requiredPlaybackModifyScopes
            )
        }
        if path.hasPrefix("/v1/me/player/") {
            return SpotifyScopeRequirement(allOf: method == "GET"
                ? SpotifyAuthConfiguration.requiredPlaybackReadScopes
                : SpotifyAuthConfiguration.requiredPlaybackModifyScopes)
        }
        if path.hasPrefix("/v1/playlists/") && method != "GET" {
            // The playlist's visibility is not present in every summary, so
            // either modification scope is sufficient for the preflight.
            return SpotifyScopeRequirement(anyOf: SpotifyAuthConfiguration.requiredPlaylistModifyScopes)
        }
        // A playlist item's 403 can mean a private followed playlist rather
        // than a missing OAuth scope, so leave GET /playlists/{id}/items as a
        // generic denial unless Spotify explicitly supplies scope metadata.
        return SpotifyScopeRequirement()
    }

    /// Refuse a feature before its HTTP request when the live auth model knows
    /// the token lacks the capability. Token-only test/catalog clients do not
    /// provide scope information and intentionally skip this preflight.
    func enforceScopeRequirement(for request: URLRequest) async throws {
        guard let scopeProvider else { return }
        let requirement = scopeRequirement(for: request)
        guard !requirement.isEmpty else { return }
        let missing = requirement.missingScopes(from: await scopeProvider.grantedScopes())
        guard !missing.isEmpty else { return }

        let details = "Scope preflight denied \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "<missing URL>"): missing \(missing.joined(separator: ", "))"
        SpotiglassLog.error(.api, details)
        throw SpotifyAPIError.insufficientScope(
            requiredScopes: missing,
            message: nil,
            details: details
        )
    }

    private func logRequestFailure(request: URLRequest?, method: String, fallbackPath: String, error: Error) {
        let target = request?.url?.absoluteString ?? fallbackPath
        let details = (error as? SpotifyAPIError)?.diagnosticDetails.map { "\n\($0)" } ?? ""
        SpotiglassLog.error(.api, "Spotify API failure: \(method) \(target) — \(error.localizedDescription)\(details)")
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
