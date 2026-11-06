import Foundation

enum MusicRequestCacheMode: Equatable {
    case freshOnly
    case allowStale
    case bypassCache
}

struct MusicCachedResponse<Value> {
    let value: Value
    let isStale: Bool
}

struct MusicArtistAlbumsPage {
    let items: [MusicArtistAlbum]
    let next: URL?
}

protocol MusicBrowsingProvider {
    func currentUserPlaylists(limit: Int) async throws -> [MusicPlaylistSummary]
    func playlistTracks(playlistID: String, limit: Int, maxPages: Int) async throws -> [MusicPlaylistTrackItem]
    func currentUserSavedTracks(limit: Int, maxPages: Int?) async throws -> MusicSavedTracksResult
    func currentUserProfile() async throws -> MusicUserProfile
    func artist(id: String, cacheMode: MusicRequestCacheMode) async throws -> MusicArtistDetail
    func artistCached(id: String, cacheMode: MusicRequestCacheMode) async throws -> MusicCachedResponse<MusicArtistDetail>
    func artistAlbumsCached(
        id: String,
        includeGroups: String,
        limit: Int,
        cacheMode: MusicRequestCacheMode
    ) async throws -> MusicCachedResponse<[MusicArtistAlbum]>
    func artistAlbumsPage(
        id: String,
        includeGroups: String,
        limit: Int,
        offset: Int,
        nextURL: URL?,
        cacheMode: MusicRequestCacheMode
    ) async throws -> MusicArtistAlbumsPage
    func search(query: String, limit: Int) async throws -> MusicSearchResults
    /// Home feed: recently played tracks (`user-read-recently-played` scope).
    func recentlyPlayedTracks(limit: Int, cacheMode: MusicRequestCacheMode) async throws -> [MusicTrack]
    /// Home feed: the user's top tracks (`user-top-read` scope).
    func topTracks(limit: Int, timeRange: String, cacheMode: MusicRequestCacheMode) async throws -> [MusicTrack]
    /// The user's top artists (`user-top-read` scope), used as a ranking signal
    /// for tracks already present in the library.
    func topArtists(limit: Int, timeRange: String, cacheMode: MusicRequestCacheMode) async throws -> [MusicArtist]
    /// Artists followed by the current user (`user-follow-read` scope).
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

extension SpotifyAPIClient: MusicBrowsingProvider {}

extension MusicBrowsingProvider {
    func albumTracksFirstPage(albumID: String, market: String?, limit: Int) async throws -> [MusicTrack] {
        try await albumTracks(albumID: albumID, market: market, limit: limit)
    }

    // Default empty home-feed implementations so preview/test mocks that don't
    // exercise the home surface compile without overrides. The live
    // `SpotifyAPIClient` provides real implementations.
    func recentlyPlayedTracks(limit: Int, cacheMode: MusicRequestCacheMode) async throws -> [MusicTrack] { [] }
    func topTracks(limit: Int, timeRange: String, cacheMode: MusicRequestCacheMode) async throws -> [MusicTrack] { [] }
    func topArtists(limit: Int, timeRange: String, cacheMode: MusicRequestCacheMode) async throws -> [MusicArtist] { [] }
    func followedArtists(limit: Int, maxPages: Int?) async throws -> [MusicArtist] { [] }
    func artistTopTracks(id: String, market: String?, cacheMode: MusicRequestCacheMode) async throws -> [MusicTrack] { [] }

    // Default no-op implementations for library mutations. Mocks/previews that
    // never exercise the menu can ignore these; the live `SpotifyAPIClient`
    // override hits the Spotify Web API.
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
