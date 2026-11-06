import Foundation

/// How a browsing request may use a provider's response cache.
enum MusicRequestCacheMode: Equatable {
    /// Use a cached response only while it is still fresh.
    case freshOnly
    /// Accept an expired cached response and report it as stale.
    case allowStale
    /// Always go to the service.
    case bypassCache
}

/// A value plus whether it came from an expired cache entry.
struct MusicCachedResponse<Value> {
    let value: Value
    let isStale: Bool
}

/// One page of an artist's albums. `next` is an opaque continuation the same
/// provider understands; callers hand it back unchanged and never build one.
struct MusicArtistAlbumsPage {
    let items: [MusicArtistAlbum]
    let next: URL?
}

/// Everything the browser reads from (and writes to) a music service's
/// catalog and the signed-in user's library: home feed, library playlists,
/// playlist / album / artist detail, liked tracks and search.
///
/// View models and views depend on this protocol only. Spotify is the first
/// implementation (`SpotifyAPIClient`, see
/// `Services/SpotifyAPIClient+MusicBrowsingProvider.swift`). The shape is meant
/// to fit Apple Music through MusicKit as well (`MusicLibraryRequest`,
/// `MusicCatalogSearchRequest`, `MusicRecentlyPlayedRequest`,
/// `MusicPersonalRecommendationsRequest`); requirements a service cannot serve
/// keep their default implementation: empty results for feeds, which the
/// browser shows as an empty section, or an "unsupported" error for edits.
protocol MusicBrowsingProvider {
    func currentUserPlaylists(limit: Int) async throws -> [MusicPlaylistSummary]
    func playlistTracks(playlistID: String, limit: Int, maxPages: Int) async throws -> [MusicPlaylistTrackItem]
    func currentUserSavedTracks(limit: Int, maxPages: Int?) async throws -> MusicSavedTracksResult
    func currentUserProfile() async throws -> MusicUserProfile
    func artist(id: String, cacheMode: MusicRequestCacheMode) async throws -> MusicArtistDetail
    func artistCached(id: String, cacheMode: MusicRequestCacheMode) async throws -> MusicCachedResponse<MusicArtistDetail>
    func artistAlbumsCached(
        id: String,
        includeGroups: [MusicArtistAlbumGroup],
        limit: Int,
        cacheMode: MusicRequestCacheMode
    ) async throws -> MusicCachedResponse<[MusicArtistAlbum]>
    func artistAlbumsPage(
        id: String,
        includeGroups: [MusicArtistAlbumGroup],
        limit: Int,
        offset: Int,
        nextURL: URL?,
        cacheMode: MusicRequestCacheMode
    ) async throws -> MusicArtistAlbumsPage
    func search(query: String, limit: Int) async throws -> MusicSearchResults
    /// Paged catalog search for the full Search view; `offset` pages past the first results.
    func search(query: String, limit: Int, offset: Int, cacheMode: MusicRequestCacheMode) async throws -> MusicSearchResults
    /// Home feed: recently played tracks.
    func recentlyPlayedTracks(limit: Int, cacheMode: MusicRequestCacheMode) async throws -> [MusicTrack]
    /// Home feed: the user's top tracks.
    func topTracks(limit: Int, timeRange: MusicTopItemsTimeRange, cacheMode: MusicRequestCacheMode) async throws -> [MusicTrack]
    /// The user's top artists, used as a ranking signal
    /// for tracks already present in the library.
    func topArtists(limit: Int, timeRange: MusicTopItemsTimeRange, cacheMode: MusicRequestCacheMode) async throws -> [MusicArtist]
    /// Artists followed by the current user.
    func followedArtists(limit: Int, maxPages: Int?) async throws -> [MusicArtist]
    /// Artist top tracks are optional breadth data. The continuation collector
    /// intersects them with the user's own tracks before ranking.
    func artistTopTracks(id: String, market: String?, cacheMode: MusicRequestCacheMode) async throws -> [MusicTrack]
    func albumTracks(albumID: String, market: String?, limit: Int) async throws -> [MusicTrack]
    /// Single-page album tracks fetch for the artist fallback. Default-implemented against
    /// `albumTracks` for mocks; the live client uses a true `maxPages: 1` call so each selected
    /// album contributes at most one HTTP request.
    func albumTracksFirstPage(albumID: String, market: String?, limit: Int) async throws -> [MusicTrack]
    // MARK: - Library write ops (mutating)

    func updatePlaylist(playlistID: String, name: String) async throws
    func addTracksToPlaylist(playlistID: String, uris: [String]) async throws
    func removeTracksFromPlaylist(
        playlistID: String,
        items: [MusicPlaylistTrackRemoval],
        snapshotID: String?
    ) async throws
    func createPlaylist(userID: String, name: String, isPublic: Bool) async throws -> MusicPlaylistSummary
    func saveTracks(ids: [String]) async throws
    func removeSavedTracks(ids: [String]) async throws
    func savedTrackStatuses(ids: [String]) async throws -> [Bool]
}

extension MusicBrowsingProvider {
    /// Providers without paged search serve the first page only.
    func search(query: String, limit: Int, offset: Int, cacheMode: MusicRequestCacheMode) async throws -> MusicSearchResults {
        guard offset == 0 else {
            return MusicSearchResults(tracks: [], artists: [], albums: [], playlists: [])
        }
        return try await search(query: query, limit: limit)
    }

    func albumTracksFirstPage(albumID: String, market: String?, limit: Int) async throws -> [MusicTrack] {
        try await albumTracks(albumID: albumID, market: market, limit: limit)
    }

    // Default empty home-feed implementations so preview/test mocks that don't
    // exercise the home surface compile without overrides. Real providers
    // override what their service offers.
    func recentlyPlayedTracks(limit: Int, cacheMode: MusicRequestCacheMode) async throws -> [MusicTrack] { [] }
    func topTracks(limit: Int, timeRange: MusicTopItemsTimeRange, cacheMode: MusicRequestCacheMode) async throws -> [MusicTrack] { [] }
    func topArtists(limit: Int, timeRange: MusicTopItemsTimeRange, cacheMode: MusicRequestCacheMode) async throws -> [MusicArtist] { [] }
    func followedArtists(limit: Int, maxPages: Int?) async throws -> [MusicArtist] { [] }
    func artistTopTracks(id: String, market: String?, cacheMode: MusicRequestCacheMode) async throws -> [MusicTrack] { [] }

    // Default no-op implementations for library mutations. Mocks/previews that
    // never exercise the menu can ignore these; a provider that supports
    // library edits overrides them.
    func updatePlaylist(playlistID: String, name: String) async throws {
        throw SpotifyAPIError.invalidRequest("Playlist rename is not supported by this API implementation.")
    }
    func addTracksToPlaylist(playlistID: String, uris: [String]) async throws {
        throw SpotifyAPIError.invalidRequest("Playlist mutation is not supported by this API implementation.")
    }
    func removeTracksFromPlaylist(
        playlistID: String,
        items: [MusicPlaylistTrackRemoval],
        snapshotID: String?
    ) async throws {
        throw SpotifyAPIError.invalidRequest("Playlist mutation is not supported by this API implementation.")
    }
    func createPlaylist(userID: String, name: String, isPublic: Bool) async throws -> MusicPlaylistSummary {
        throw SpotifyAPIError.invalidRequest("Playlist creation is not supported by this API implementation.")
    }
    func saveTracks(ids: [String]) async throws {
        throw SpotifyAPIError.invalidRequest("Library save is not supported by this API implementation.")
    }
    func removeSavedTracks(ids: [String]) async throws {
        throw SpotifyAPIError.invalidRequest("Library unsave is not supported by this API implementation.")
    }
    func savedTrackStatuses(ids: [String]) async throws -> [Bool] {
        throw SpotifyAPIError.invalidRequest("Saved-track status lookup is not supported by this API implementation.")
    }
}
