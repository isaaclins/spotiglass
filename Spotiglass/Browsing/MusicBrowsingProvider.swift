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

/// Library edits a provider offers beyond the ones every provider has (rename, add to and move
/// between playlists, create, like). The browser shows the matching menu items only for these.
struct MusicLibraryEdits: OptionSet {
    let rawValue: Int

    /// "Remove from This Playlist" in the track menu.
    static let removeFromPlaylist = MusicLibraryEdits(rawValue: 1 << 0)
    /// "Delete Playlist…" in the playlist menus.
    static let deletePlaylist = MusicLibraryEdits(rawValue: 1 << 1)
    /// "Add Album to Library" / "Remove Album from Library" on an album.
    static let saveAlbums = MusicLibraryEdits(rawValue: 1 << 2)
    /// Removing a song from Liked Songs or an album from the library deletes it from the library,
    /// which also takes it out of every playlist on every device (Apple Music), so the browser
    /// asks first. Spotify's unlike only leaves Liked Songs and goes through at once.
    static let confirmLibraryRemoval = MusicLibraryEdits(rawValue: 1 << 3)
    /// Dragging rows to a new spot in a playlist the user may edit (#543).
    static let reorderPlaylistTracks = MusicLibraryEdits(rawValue: 1 << 4)

    static let all: MusicLibraryEdits = [.removeFromPlaylist, .deletePlaylist, .saveAlbums, .confirmLibraryRemoval, .reorderPlaylistTracks]
}

/// Whether the signed-in account may make a library edit, asked before the request goes out.
/// Each service maps its own rule into it (Spotify: OAuth scopes,
/// ``SpotifyLibraryEditPermissions``); the browser only sees the failure to show.
protocol MusicLibraryEditPermissions {
    /// The failure to show when the account may not make `operation`; `nil` lets it go ahead.
    func missingPermission(for operation: PlaylistMutationOperation) async -> Error?
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
    /// Track counts for library playlists listed without one, keyed by playlist ID. The browser
    /// asks after the sidebar is on screen, a batch at a time; IDs without a known count are left
    /// out and their rows show no count. Spotify lists counts with the playlists, so its default
    /// is empty.
    func playlistTrackCounts(playlistIDs: [String]) async -> [String: Int]
    /// True when the playlist listing comes without track counts and the browser asks
    /// `playlistTrackCounts` for them (Apple Music). Spotify lists them, so nothing changes there.
    var listsPlaylistsWithoutTrackCounts: Bool { get }
    func playlistTracks(playlistID: String, limit: Int, maxPages: Int) async throws -> [MusicPlaylistTrackItem]
    /// A playlist's tracks as the provider last read them, possibly out of date, to show while
    /// `playlistTracks` reads the current ones; `nil` when it has none (#442). The default has none.
    func lastReadPlaylistTracks(playlistID: String) async -> [MusicPlaylistTrackItem]?
    func currentUserSavedTracks(limit: Int, maxPages: Int?) async throws -> MusicSavedTracksResult
    /// `currentUserSavedTracks`, handing the first page to `firstPage` as soon as it is read, so
    /// the list shows it while the rest loads (#442). The default reads everything first and
    /// never calls it.
    func currentUserSavedTracks(
        limit: Int,
        maxPages: Int?,
        firstPage: @escaping @Sendable (MusicSavedTracksResult) async -> Void
    ) async throws -> MusicSavedTracksResult
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
    /// Saves a new order for a playlist's rows (`MusicLibraryEdits.reorderPlaylistTracks`).
    /// Returns the playlist's new snapshot ID when the service has one (Spotify).
    func reorderPlaylistTracks(
        playlistID: String,
        reorder: MusicPlaylistReorder,
        snapshotID: String?
    ) async throws -> String?
    func createPlaylist(userID: String, name: String, isPublic: Bool) async throws -> MusicPlaylistSummary
    /// Creates a playlist with these tracks. The default creates it, then adds them; a provider
    /// that can do both in one step overrides it, so a failed add leaves no empty playlist.
    func createPlaylist(userID: String, name: String, isPublic: Bool, trackURIs: [String]) async throws -> MusicPlaylistSummary
    func saveTracks(ids: [String]) async throws
    func removeSavedTracks(ids: [String]) async throws
    func savedTrackStatuses(ids: [String]) async throws -> [Bool]
    /// Whether a track is saved, when the provider knows it without a request (an Apple Music
    /// song listed from the library is in the library). `nil` asks `savedTrackStatuses`.
    func knownSavedTrackStatus(id: String) -> Bool?
    /// The optional edits this provider supports; the browser hides the others.
    var supportedLibraryEdits: MusicLibraryEdits { get }
    func deletePlaylist(playlistID: String) async throws
    func saveAlbums(ids: [String]) async throws
    func removeSavedAlbums(ids: [String]) async throws
    func savedAlbumStatuses(ids: [String]) async throws -> [Bool]
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

    // Default implementations for library mutations. Mocks/previews that never
    // exercise the menu can ignore these; a provider that supports library edits
    // overrides them. The failure belongs to no service, so it never reads as
    // Spotify's or Apple Music's (#388).
    func updatePlaylist(playlistID: String, name: String) async throws {
        throw MusicBrowsingError(unsupportedOperation: "Playlist rename")
    }
    func addTracksToPlaylist(playlistID: String, uris: [String]) async throws {
        throw MusicBrowsingError(unsupportedOperation: "Playlist mutation")
    }
    func removeTracksFromPlaylist(
        playlistID: String,
        items: [MusicPlaylistTrackRemoval],
        snapshotID: String?
    ) async throws {
        throw MusicBrowsingError(unsupportedOperation: "Playlist mutation")
    }
    func reorderPlaylistTracks(
        playlistID: String,
        reorder: MusicPlaylistReorder,
        snapshotID: String?
    ) async throws -> String? {
        throw MusicBrowsingError(unsupportedOperation: "Playlist reorder")
    }
    func createPlaylist(userID: String, name: String, isPublic: Bool) async throws -> MusicPlaylistSummary {
        throw MusicBrowsingError(unsupportedOperation: "Playlist creation")
    }
    func createPlaylist(userID: String, name: String, isPublic: Bool, trackURIs: [String]) async throws -> MusicPlaylistSummary {
        let created = try await createPlaylist(userID: userID, name: name, isPublic: isPublic)
        if !trackURIs.isEmpty {
            try await addTracksToPlaylist(playlistID: created.id, uris: trackURIs)
        }
        return created
    }
    func knownSavedTrackStatus(id: String) -> Bool? { nil }
    func saveTracks(ids: [String]) async throws {
        throw MusicBrowsingError(unsupportedOperation: "Library save")
    }
    func removeSavedTracks(ids: [String]) async throws {
        throw MusicBrowsingError(unsupportedOperation: "Library unsave")
    }
    func savedTrackStatuses(ids: [String]) async throws -> [Bool] {
        throw MusicBrowsingError(unsupportedOperation: "Saved-track status lookup")
    }

    func currentUserSavedTracks(
        limit: Int,
        maxPages: Int?,
        firstPage: @escaping @Sendable (MusicSavedTracksResult) async -> Void
    ) async throws -> MusicSavedTracksResult {
        try await currentUserSavedTracks(limit: limit, maxPages: maxPages)
    }

    func lastReadPlaylistTracks(playlistID: String) async -> [MusicPlaylistTrackItem]? { nil }

    func playlistTrackCounts(playlistIDs: [String]) async -> [String: Int] { [:] }
    var listsPlaylistsWithoutTrackCounts: Bool { false }

    var supportedLibraryEdits: MusicLibraryEdits { [] }
    func deletePlaylist(playlistID: String) async throws {
        throw MusicBrowsingError(unsupportedOperation: "Playlist deletion")
    }
    func saveAlbums(ids: [String]) async throws {
        throw MusicBrowsingError(unsupportedOperation: "Album save")
    }
    func removeSavedAlbums(ids: [String]) async throws {
        throw MusicBrowsingError(unsupportedOperation: "Album unsave")
    }
    func savedAlbumStatuses(ids: [String]) async throws -> [Bool] {
        throw MusicBrowsingError(unsupportedOperation: "Saved-album status lookup")
    }
}
