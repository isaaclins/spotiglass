import Foundation

extension SpotifyAPIClient {
    func artist(id: String, cacheMode: SpotifyRequestCacheMode = .freshOnly) async throws -> SpotifyArtistDetail {
        guard !id.isEmpty else {
            throw SpotifyAPIError.invalidRequest("Artist ID is required.")
        }
        let dto: SpotifyArtistDetailDTO = try await send(path: "/v1/artists/\(id)", cacheMode: cacheMode)
        return dto.domainModel()
    }

    func artistCached(id: String, cacheMode: SpotifyRequestCacheMode = .allowStale) async throws -> CachedResponse<SpotifyArtistDetail> {
        guard !id.isEmpty else {
            throw SpotifyAPIError.invalidRequest("Artist ID is required.")
        }
        let cached: CachedResponse<SpotifyArtistDetailDTO> = try await sendCached(path: "/v1/artists/\(id)", cacheMode: cacheMode)
        return CachedResponse(value: cached.value.domainModel(), isStale: cached.isStale)
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
}
