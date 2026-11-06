import Foundation
import MusicKit

/// Browsing failures specific to Apple Music.
enum AppleMusicBrowsingError: LocalizedError, Equatable {
    /// The playlist, album or artist is neither in the library nor in the catalog.
    case notFound

    var errorDescription: String? {
        switch self {
        case .notFound:
            SpotiglassL10n.string("appleMusic.error.notFound")
        }
    }
}

/// `MusicBrowsingProvider` for Apple Music, through MusicKit.
///
/// How the browser's surfaces map onto Apple Music:
/// - **Library playlists**: `MusicLibraryRequest<Playlist>`, most recently played first.
/// - **Liked Songs**: the songs in the user's library, newest first. Apple Music has no
///   separate "liked" list a native app can read; loving a song is a rating, and MusicKit on
///   macOS offers no request for loved songs. The library is what the user chose to keep, which
///   is what Liked Songs is on Spotify.
/// - **Home**: "Recently played" is `MusicRecentlyPlayedRequest<Song>`. "Your top tracks" are the
///   songs of the user's personal mix from `MusicPersonalRecommendationsRequest` (Apple's
///   Favourites / Heavy Rotation mixes are built from what the user plays most), falling back to
///   the first recommended playlist.
/// - **Search**: library matches first, then the catalog, so the palette finds the user's own
///   music before the rest of Apple Music. Later pages are catalog only.
/// - **Edits**: not supported here (MusicKit's library is read-only on macOS); the protocol's
///   defaults report them as unsupported.
///
/// Response caching is MusicKit's own, so `cacheMode` is accepted and ignored.
struct AppleMusicBrowsingProvider: MusicBrowsingProvider {
    /// The library has no account ID a native app can read. This constant stands in for it, so
    /// pins and library row order are kept apart from every Spotify account.
    static let libraryUserID = "apple-music-library"
    /// Upper bound for Liked Songs, so a very large library cannot grow without limit.
    static let maxLibrarySongs = 10_000
    static let librarySongsPageSize = 200

    let source: any AppleMusicContentSource

    init(source: any AppleMusicContentSource = MusicKitContentSource()) {
        self.source = source
    }

    private var libraryOwnerName: String {
        SpotiglassL10n.string("appleMusic.library.owner")
    }

    // MARK: - Profile and library

    func currentUserProfile() async throws -> MusicUserProfile {
        let country = try? await source.storefrontCountryCode()
        return MusicUserProfile(id: Self.libraryUserID, displayName: nil, country: country?.uppercased())
    }

    func currentUserPlaylists(limit: Int) async throws -> [MusicPlaylistSummary] {
        try await source.libraryPlaylists(limit: limit).map {
            AppleMusicItemMapping.playlistSummary($0, fallbackOwnerName: libraryOwnerName)
        }
    }

    func playlistTracks(playlistID: String, limit: Int, maxPages: Int) async throws -> [MusicPlaylistTrackItem] {
        let total = max(1, limit) * max(1, maxPages)
        guard let tracks = try await source.playlistTracks(playlistID: playlistID, limit: total) else {
            throw AppleMusicBrowsingError.notFound
        }
        return AppleMusicItemMapping.playlistItems(tracks.map { AppleMusicItemMapping.track($0) })
    }

    func currentUserSavedTracks(limit: Int, maxPages: Int?) async throws -> MusicSavedTracksResult {
        let pageSize = max(limit, Self.librarySongsPageSize)
        let cap = maxPages.map { min(Self.maxLibrarySongs, max(1, $0) * max(1, limit)) } ?? Self.maxLibrarySongs
        var songs: [Song] = []
        while songs.count < cap {
            try Task.checkCancellation()
            let requested = min(pageSize, cap - songs.count)
            let page = try await source.librarySongs(limit: requested, offset: songs.count)
            songs.append(contentsOf: page)
            if page.count < requested { break }
        }
        let tracks = songs.map(AppleMusicItemMapping.track)
        return MusicSavedTracksResult(
            tracks: AppleMusicItemMapping.playlistItems(tracks),
            totalAvailable: tracks.count
        )
    }

    // MARK: - Home

    func recentlyPlayedTracks(limit: Int, cacheMode: MusicRequestCacheMode) async throws -> [MusicTrack] {
        try await source.recentlyPlayedSongs(limit: limit).map(AppleMusicItemMapping.track)
    }

    func topTracks(limit: Int, timeRange: MusicTopItemsTimeRange, cacheMode: MusicRequestCacheMode) async throws -> [MusicTrack] {
        let playlists = try await source.recommendedPlaylists()
        guard let mix = playlists.first(where: { $0.kind == .personalMix }) ?? playlists.first,
              let tracks = try await source.playlistTracks(playlistID: mix.id.rawValue, limit: limit)
        else { return [] }
        return tracks.map { AppleMusicItemMapping.track($0) }
    }

    // MARK: - Detail

    func albumTracks(albumID: String, market: String?, limit: Int) async throws -> [MusicTrack] {
        guard let album = try await source.album(id: albumID) else {
            throw AppleMusicBrowsingError.notFound
        }
        let tracks = album.tracks.map(Array.init) ?? []
        return tracks.prefix(limit).map { AppleMusicItemMapping.track($0, album: album) }
    }

    func artist(id: String, cacheMode: MusicRequestCacheMode) async throws -> MusicArtistDetail {
        AppleMusicItemMapping.artistDetail(try await loadArtist(id: id))
    }

    func artistCached(id: String, cacheMode: MusicRequestCacheMode) async throws -> MusicCachedResponse<MusicArtistDetail> {
        MusicCachedResponse(value: try await artist(id: id, cacheMode: cacheMode), isStale: false)
    }

    func artistAlbumsCached(
        id: String,
        includeGroups: [MusicArtistAlbumGroup],
        limit: Int,
        cacheMode: MusicRequestCacheMode
    ) async throws -> MusicCachedResponse<[MusicArtistAlbum]> {
        let albums = try await artistAlbums(id: id, includeGroups: includeGroups)
        return MusicCachedResponse(value: Array(albums.prefix(limit)), isStale: false)
    }

    /// MusicKit returns an artist's albums in one go, so this pages over that list by offset.
    /// `next` is never a URL a caller could follow outside this provider.
    func artistAlbumsPage(
        id: String,
        includeGroups: [MusicArtistAlbumGroup],
        limit: Int,
        offset: Int,
        nextURL: URL?,
        cacheMode: MusicRequestCacheMode
    ) async throws -> MusicArtistAlbumsPage {
        let albums = try await artistAlbums(id: id, includeGroups: includeGroups)
        let start = min(max(0, offset), albums.count)
        let end = min(start + max(1, limit), albums.count)
        let next = end < albums.count ? Self.continuationURL(offset: end) : nil
        return MusicArtistAlbumsPage(items: Array(albums[start..<end]), next: next)
    }

    func artistTopTracks(id: String, market: String?, cacheMode: MusicRequestCacheMode) async throws -> [MusicTrack] {
        try await source.artistTopSongs(artistID: id).map(AppleMusicItemMapping.track)
    }

    private func loadArtist(id: String) async throws -> Artist {
        guard let artist = try await source.artist(id: id) else {
            throw AppleMusicBrowsingError.notFound
        }
        return artist
    }

    private func artistAlbums(id: String, includeGroups: [MusicArtistAlbumGroup]) async throws -> [MusicArtistAlbum] {
        let artist = try await loadArtist(id: id)
        let groups = Set(includeGroups)
        return (artist.albums.map(Array.init) ?? [])
            .map(AppleMusicItemMapping.artistAlbum)
            .filter { groups.isEmpty || groups.contains($0.group) }
    }

    // MARK: - Search

    func search(query: String, limit: Int) async throws -> MusicSearchResults {
        try await search(query: query, limit: limit, offset: 0, cacheMode: .freshOnly)
    }

    func search(query: String, limit: Int, offset: Int, cacheMode: MusicRequestCacheMode) async throws -> MusicSearchResults {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            return MusicSearchResults(tracks: [], artists: [], albums: [], playlists: [])
        }
        let pageLimit = min(max(1, limit), MusicKitContentSource.catalogSearchPageLimit)

        async let catalogResult = Self.capture { try await source.catalogSearch(term: term, limit: pageLimit, offset: offset) }
        async let libraryResult = Self.capture {
            offset == 0 ? try await source.librarySearch(term: term, limit: pageLimit) : AppleMusicSearchItems()
        }
        let (catalog, library) = await (catalogResult, libraryResult)
        if case let .failure(error) = catalog, case .failure = library {
            throw error
        }
        let catalogItems = (try? catalog.get()) ?? AppleMusicSearchItems()
        let libraryItems = (try? library.get()) ?? AppleMusicSearchItems()

        let paging = MusicSearchPaging(
            total: offset + pageLimit + (catalogItems.hasMore ? pageLimit : 0),
            next: catalogItems.hasMore ? Self.continuationURL(offset: offset + pageLimit) : nil
        )
        return MusicSearchResults(
            tracks: Self.merged(libraryItems.songs, catalogItems.songs, limit: limit) {
                "\($0.title)|\($0.artistName)".lowercased()
            }.map(AppleMusicItemMapping.track),
            artists: Self.merged(libraryItems.artists, catalogItems.artists, limit: limit) {
                $0.name.lowercased()
            }.map(AppleMusicItemMapping.artist),
            albums: Self.merged(libraryItems.albums, catalogItems.albums, limit: limit) {
                "\($0.title)|\($0.artistName)".lowercased()
            }.map(AppleMusicItemMapping.album),
            playlists: Self.merged(libraryItems.playlists, catalogItems.playlists, limit: limit) {
                $0.id.rawValue
            }.map { AppleMusicItemMapping.playlistSummary($0, fallbackOwnerName: libraryOwnerName) },
            tracksPaging: paging,
            artistsPaging: paging,
            albumsPaging: paging,
            playlistsPaging: paging
        )
    }

    // MARK: - Helpers

    /// An opaque continuation in the `offset` shape the Search view already reads.
    static func continuationURL(offset: Int) -> URL? {
        var components = URLComponents()
        components.scheme = AppleMusicItemMapping.uriScheme
        components.host = "page"
        components.queryItems = [URLQueryItem(name: "offset", value: String(offset))]
        return components.url
    }

    /// Library items first, then catalog items the library does not already show.
    static func merged<Item>(_ library: [Item], _ catalog: [Item], limit: Int, key: (Item) -> String) -> [Item] {
        var seen: Set<String> = []
        var result: [Item] = []
        for item in library + catalog where seen.insert(key(item)).inserted {
            result.append(item)
            if result.count >= limit { break }
        }
        return result
    }

    private static func capture<Value>(_ body: () async throws -> Value) async -> Result<Value, Error> {
        do {
            return .success(try await body())
        } catch {
            return .failure(error)
        }
    }
}
