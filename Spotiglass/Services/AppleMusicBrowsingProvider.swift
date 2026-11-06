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
/// - **Library playlists**: `MusicLibraryRequest<Playlist>`, in the library's own order (sorting
///   by last played aborts MusicKit's macOS library backend), every page of them.
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
    /// Upper bound for library playlists; far above any real library, it only stops a runaway.
    static let maxLibraryPlaylists = 5_000
    /// Library matches per type on the first search page.
    static let maxLibrarySearchMatches = 100
    /// Pages of album tracks `albumTracks` follows, the same as the Spotify client.
    static let albumTrackPages = 6
    /// Upper bound for one artist's albums, singles and compilations.
    static let maxArtistAlbums = 1_000

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

    /// `limit` is the page size, like Spotify's: every library playlist is returned, not only the
    /// first page.
    func currentUserPlaylists(limit: Int) async throws -> [MusicPlaylistSummary] {
        let pageSize = max(1, limit)
        var playlists: [Playlist] = []
        while playlists.count < Self.maxLibraryPlaylists {
            try Task.checkCancellation()
            let requested = min(pageSize, Self.maxLibraryPlaylists - playlists.count)
            let page = try await source.libraryPlaylists(limit: requested, offset: playlists.count)
            playlists.append(contentsOf: page)
            if page.count < requested { break }
        }
        return playlists.map {
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

    /// `limit` is a page size, like Spotify's, which follows up to six pages of album tracks.
    func albumTracks(albumID: String, market: String?, limit: Int) async throws -> [MusicTrack] {
        try await albumTracks(albumID: albumID, upTo: max(1, limit) * Self.albumTrackPages)
    }

    /// Only the first page, for the artist fallback that samples many albums.
    func albumTracksFirstPage(albumID: String, market: String?, limit: Int) async throws -> [MusicTrack] {
        try await albumTracks(albumID: albumID, upTo: max(1, limit))
    }

    private func albumTracks(albumID: String, upTo cap: Int) async throws -> [MusicTrack] {
        guard let album = try await source.album(id: albumID) else {
            throw AppleMusicBrowsingError.notFound
        }
        let tracks = try await source.tracks(of: album, limit: cap)
        return tracks.prefix(cap).map { AppleMusicItemMapping.track($0, album: album) }
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
        return try await source.albums(of: artist, limit: Self.maxArtistAlbums)
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
            // The library can't be paged (no offset in MusicKit), so the first page carries all
            // of its matches, up to a bound; later pages are catalog only.
            offset == 0
                ? try await source.librarySearch(term: term, limit: Self.maxLibrarySearchMatches)
                : AppleMusicSearchItems()
        }
        let (catalog, library) = await (catalogResult, libraryResult)
        // Past the first page only the catalog answers, so its failure is the page's failure:
        // reporting an empty page would end the results instead of letting the user retry.
        if case let .failure(error) = catalog {
            if offset > 0 { throw error }
            if case .failure = library { throw error }
        }
        let catalogItems = (try? catalog.get()) ?? AppleMusicSearchItems()
        let libraryItems = (try? library.get()) ?? AppleMusicSearchItems()

        let next = catalogItems.hasMore ? Self.continuationURL(offset: offset + pageLimit) : nil
        // `total` must not promise more than there is: the Search view keeps Load More while
        // `offset + items < total`, so a made-up total on the last page pages forever.
        func paging(_ count: Int) -> MusicSearchPaging {
            MusicSearchPaging(total: offset + count + (next == nil ? 0 : pageLimit), next: next)
        }
        // The match key says "same recording" across library and catalog, whose IDs differ:
        // title, artist, album and rating (a clean and an explicit version share the rest).
        let tracks = Self.merged(libraryItems.songs, catalogItems.songs, limit: limit, id: { $0.id.rawValue }) {
            "\($0.title)|\($0.artistName)|\($0.albumTitle ?? "")|\($0.contentRating == .explicit)".lowercased()
        }
        // Artists match by name on purpose: the same artist in the library and in the catalog
        // is far more common than two different artists with one name, one of them saved.
        let artists = Self.merged(libraryItems.artists, catalogItems.artists, limit: limit, id: { $0.id.rawValue }) {
            $0.name.lowercased()
        }
        let albums = Self.merged(libraryItems.albums, catalogItems.albums, limit: limit, id: { $0.id.rawValue }) {
            "\($0.title)|\($0.artistName)|\($0.contentRating == .explicit)".lowercased()
        }
        let playlists = Self.merged(libraryItems.playlists, catalogItems.playlists, limit: limit, id: { $0.id.rawValue }) {
            $0.id.rawValue
        }
        return MusicSearchResults(
            tracks: tracks.map(AppleMusicItemMapping.track),
            artists: artists.map(AppleMusicItemMapping.artist),
            albums: albums.map(AppleMusicItemMapping.album),
            playlists: playlists.map { AppleMusicItemMapping.playlistSummary($0, fallbackOwnerName: libraryOwnerName) },
            tracksPaging: paging(tracks.count),
            artistsPaging: paging(artists.count),
            albumsPaging: paging(albums.count),
            playlistsPaging: paging(playlists.count)
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

    /// Library items first, then the catalog items the library does not already show.
    ///
    /// The library side is already bounded by its request; the catalog side keeps up to `limit`
    /// items (its page). Library matches must not push catalog items off the
    /// page: the next page starts after this page's catalog items, so a catalog item cut here
    /// would never be shown at all. Within a side, items are told apart by `id`, so two
    /// recordings with the same title stay two rows. A catalog item is only dropped as a
    /// duplicate when the library shows the same `match` (library and catalog IDs differ for
    /// the same song).
    static func merged<Item>(
        _ library: [Item],
        _ catalog: [Item],
        limit: Int,
        id: (Item) -> String,
        match: (Item) -> String
    ) -> [Item] {
        var seenIDs: Set<String> = []
        var libraryMatches: Set<String> = []
        var result: [Item] = []
        for item in library where seenIDs.insert(id(item)).inserted {
            libraryMatches.insert(match(item))
            result.append(item)
        }
        for item in catalog.prefix(limit)
        where !libraryMatches.contains(match(item)) && seenIDs.insert(id(item)).inserted {
            result.append(item)
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
