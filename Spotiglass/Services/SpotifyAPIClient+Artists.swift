import Foundation

extension SpotifyAPIClient {
    func artist(id: String, cacheMode: MusicRequestCacheMode = .freshOnly) async throws -> MusicArtistDetail {
        guard !id.isEmpty else {
            throw SpotifyAPIError.invalidRequest("Artist ID is required.")
        }
        let dto: SpotifyArtistDetailDTO = try await send(path: "/v1/artists/\(id)", cacheMode: cacheMode)
        return dto.domainModel()
    }

    func artistCached(id: String, cacheMode: MusicRequestCacheMode = .allowStale) async throws -> MusicCachedResponse<MusicArtistDetail> {
        guard !id.isEmpty else {
            throw SpotifyAPIError.invalidRequest("Artist ID is required.")
        }
        let cached: MusicCachedResponse<SpotifyArtistDetailDTO> = try await sendCached(path: "/v1/artists/\(id)", cacheMode: cacheMode)
        return MusicCachedResponse(value: cached.value.domainModel(), isStale: cached.isStale)
    }

    /// Top tracks for one artist (`GET /v1/artists/{id}/top-tracks`). This is
    /// optional breadth for library ranking; callers decide which returned
    /// tracks are eligible to enter a continuation.
    func artistTopTracks(
        id: String,
        market: String? = nil,
        cacheMode: MusicRequestCacheMode = .freshOnly
    ) async throws -> [MusicTrack] {
        guard !id.isEmpty else {
            throw SpotifyAPIError.invalidRequest("Artist ID is required.")
        }
        var queryItems: [URLQueryItem] = []
        if let market, !market.isEmpty {
            queryItems.append(URLQueryItem(name: "market", value: market))
        }
        let response: SpotifyArtistTopTracksResponseDTO = try await send(
            path: "/v1/artists/\(id)/top-tracks",
            queryItems: queryItems,
            cacheMode: cacheMode
        )
        return response.tracks.compactMap { $0.domainModel() }
    }

    /// Single page from `GET /v1/artists/{id}/albums`, using either explicit
    /// offset pagination (first page) or Spotify-provided `next` URLs.
    func artistAlbumsPage(
        id: String,
        includeGroups: [MusicArtistAlbumGroup] = MusicArtistAlbumGroup.allCases,
        limit: Int = 10,
        offset: Int = 0,
        nextURL: URL? = nil,
        cacheMode: MusicRequestCacheMode = .freshOnly
    ) async throws -> MusicArtistAlbumsPage {
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
                    URLQueryItem(name: "include_groups", value: Self.includeGroupsQueryValue(includeGroups)),
                    URLQueryItem(name: "limit", value: String(effectiveLimit)),
                    URLQueryItem(name: "offset", value: String(max(0, offset)))
                ],
                cacheMode: cacheMode
            )
        }
        return MusicArtistAlbumsPage(
            items: page.items.compactMap { $0.domainModel() },
            next: page.next
        )
    }

    func artistAlbumsCached(
        id: String,
        includeGroups: [MusicArtistAlbumGroup] = MusicArtistAlbumGroup.allCases,
        limit: Int = 10,
        cacheMode: MusicRequestCacheMode = .allowStale
    ) async throws -> MusicCachedResponse<[MusicArtistAlbum]> {
        guard !id.isEmpty else {
            throw SpotifyAPIError.invalidRequest("Artist ID is required.")
        }
        let effectiveLimit = min(max(1, limit), 10)
        let path = "/v1/artists/\(id)/albums"
        let queryItems = [
            URLQueryItem(name: "include_groups", value: Self.includeGroupsQueryValue(includeGroups)),
            URLQueryItem(name: "limit", value: String(effectiveLimit)),
            URLQueryItem(name: "offset", value: "0")
        ]
        let page: MusicCachedResponse<SpotifyPagingDTO<SpotifyArtistAlbumDTO>> = try await sendCached(
            path: path,
            queryItems: queryItems,
            cacheMode: cacheMode
        )
        return MusicCachedResponse(
            value: page.value.items.compactMap { $0.domainModel() },
            isStale: page.isStale
        )
    }

    /// Spotify's `include_groups` parameter: comma-separated group names in the given order.
    static func includeGroupsQueryValue(_ groups: [MusicArtistAlbumGroup]) -> String {
        groups.map(\.rawValue).joined(separator: ",")
    }
}
