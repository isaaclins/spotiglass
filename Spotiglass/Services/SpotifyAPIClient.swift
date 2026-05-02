import Foundation

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
    private let baseURL: URL
    private let tokenProvider: SpotifyAccessTokenProviding
    private let httpClient: HTTPClient
    private let decoder: JSONDecoder

    init(
        baseURL: URL = URL(string: "https://api.spotify.com")!,
        tokenProvider: SpotifyAccessTokenProviding,
        httpClient: HTTPClient = URLSession.shared
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.httpClient = httpClient
        self.decoder = JSONDecoder.spotifyWebAPI
    }

    func currentUserProfile() async throws -> SpotifyUserProfile {
        let dto: SpotifyUserProfileDTO = try await send(path: "/v1/me")
        return dto.domainModel()
    }

    func artist(id: String) async throws -> SpotifyArtistDetail {
        guard !id.isEmpty else {
            throw SpotifyAPIError.invalidRequest("Artist ID is required.")
        }
        let dto: SpotifyArtistDetailDTO = try await send(path: "/v1/artists/\(id)")
        return dto.domainModel()
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

    /// Tracks on an album (`GET /v1/albums/{id}/tracks`). Paginates until `next` is nil.
    func albumTracks(albumID: String, market: String?, limit: Int = 50) async throws -> [SpotifyTrack] {
        guard !albumID.isEmpty else {
            throw SpotifyAPIError.invalidRequest("Album ID is required.")
        }
        var results: [SpotifyTrack] = []
        var nextURL: URL?
        repeat {
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
            results.append(contentsOf: page.items.compactMap { $0.domainModel() })
            nextURL = page.next
        } while nextURL != nil

        return results
    }

    /// Spotify documents `GET /v1/artists/{id}/albums` with **maximum `limit` of 10**. Larger values return HTTP 400.
    func artistAlbums(id: String, includeGroups: String = "album,single,compilation,appears_on", limit: Int = 10) async throws -> [SpotifyArtistAlbum] {
        guard !id.isEmpty else {
            throw SpotifyAPIError.invalidRequest("Artist ID is required.")
        }
        let effectiveLimit = min(max(1, limit), 10)
        var results: [SpotifyArtistAlbum] = []
        var nextURL: URL?
        repeat {
            let page: SpotifyPagingDTO<SpotifyArtistAlbumDTO>
            if let url = nextURL {
                page = try await send(url: url)
            } else {
                page = try await send(
                    path: "/v1/artists/\(id)/albums",
                    queryItems: [
                        URLQueryItem(name: "include_groups", value: includeGroups),
                        URLQueryItem(name: "limit", value: String(effectiveLimit)),
                        URLQueryItem(name: "offset", value: "0")
                    ]
                )
            }
            results.append(contentsOf: page.items.compactMap { $0.domainModel() })
            nextURL = page.next
        } while nextURL != nil

        return results
    }

    func currentUserPlaylists(limit: Int = 50) async throws -> [SpotifyPlaylistSummary] {
        try await collectPaged(path: "/v1/me/playlists", limit: limit) { (dto: SpotifyPlaylistDTO, _) in
            dto.domainModel()
        }
    }

    func playlistTracks(playlistID: String, limit: Int = 50) async throws -> [SpotifyPlaylistTrackItem] {
        guard !playlistID.isEmpty else {
            throw SpotifyAPIError.invalidRequest("Playlist ID is required.")
        }
        return try await collectPaged(path: "/v1/playlists/\(playlistID)/items", limit: limit) { (dto: SpotifyPlaylistTrackItemDTO, index) in
            dto.domainModel(position: index)
        }
    }

    func search(query: String, limit: Int = 6) async throws -> SpotifySearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
        }
        let dto: SpotifySearchResponseDTO = try await send(
            path: "/v1/search",
            queryItems: [
                URLQueryItem(name: "q", value: trimmed),
                URLQueryItem(name: "type", value: "track,artist,album,playlist"),
                URLQueryItem(name: "limit", value: String(limit))
            ]
        )
        return dto.domainModel()
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
        transform: (ItemDTO, Int) -> Domain
    ) async throws -> [Domain] {
        var offset = 0
        var results: [Domain] = []
        var nextURL: URL?

        repeat {
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

            nextURL = page.next
            offset += page.limit
        } while nextURL != nil

        return results
    }

    private func send<Response: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> Response {
        let accessToken = try await tokenProvider.accessToken()
        let request = try makeRequest(path: path, queryItems: queryItems, accessToken: accessToken)
        return try await send(request: request, didRefreshAfterUnauthorized: false)
    }

    private func send<Response: Decodable>(url: URL) async throws -> Response {
        let accessToken = try await tokenProvider.accessToken()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await send(request: request, didRefreshAfterUnauthorized: false)
    }

    private func send<Response: Decodable>(
        request: URLRequest,
        didRefreshAfterUnauthorized: Bool
    ) async throws -> Response {
        do {
            let (data, response) = try await httpClient.data(for: request)
            if response.statusCode == 401 && !didRefreshAfterUnauthorized {
                let refreshedToken = try await tokenProvider.refreshAccessTokenAfterUnauthorized()
                var refreshedRequest = request
                refreshedRequest.setValue("Bearer \(refreshedToken)", forHTTPHeaderField: "Authorization")
                return try await send(request: refreshedRequest, didRefreshAfterUnauthorized: true)
            }
            guard (200..<300).contains(response.statusCode) else {
                throw mapHTTPError(
                    statusCode: response.statusCode,
                    data: data,
                    headers: response.allHeaderFields,
                    request: request
                )
            }
            do {
                return try decoder.decode(Response.self, from: data)
            } catch {
                throw SpotifyAPIError.decoding(Self.describeDecodingError(error))
            }
        } catch let apiError as SpotifyAPIError {
            throw apiError
        } catch {
            throw SpotifyAPIError.network(error.localizedDescription)
        }
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
        guard let value = headers["Retry-After"] as? String ?? headers["retry-after"] as? String else {
            return nil
        }
        return TimeInterval(value)
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
