import Foundation
@testable import Spotiglass

final class LimitCapturingBrowsingAPI: SpotifyBrowsingAPI {
    let playlists: [SpotifyPlaylistSummary]
    let tracks: [SpotifyPlaylistTrackItem]
    private(set) var lastTracksLimit: Int?
    private(set) var lastTracksMaxPages: Int?

    init(playlists: [SpotifyPlaylistSummary], tracks: [SpotifyPlaylistTrackItem]) {
        self.playlists = playlists
        self.tracks = tracks
    }

    func currentUserProfile() async throws -> SpotifyUserProfile {
        SpotifyUserProfile(id: "u", displayName: nil, country: "US")
    }

    func artist(id: String, cacheMode: SpotifyRequestCacheMode) async throws -> SpotifyArtistDetail {
        SpotifyArtistDetail(id: id, name: "Artist \(id)", imageURL: nil, followersTotal: nil, genres: [], uri: "spotify:artist:\(id)")
    }

    func artistCached(id: String, cacheMode: SpotifyRequestCacheMode) async throws -> SpotifyAPIClient.CachedResponse<SpotifyArtistDetail> {
        SpotifyAPIClient.CachedResponse(
            value: try await artist(id: id, cacheMode: cacheMode),
            isStale: false
        )
    }

    func search(query: String, limit: Int) async throws -> SpotifySearchResults {
        SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
    }

    func albumTracks(albumID: String, market: String?, limit: Int) async throws -> [SpotifyTrack] {
        []
    }

    func artistAlbumsCached(
        id: String,
        includeGroups: String,
        limit: Int,
        cacheMode: SpotifyRequestCacheMode
    ) async throws -> SpotifyAPIClient.CachedResponse<[SpotifyArtistAlbum]> {
        SpotifyAPIClient.CachedResponse(value: [], isStale: false)
    }

    func artistAlbumsPage(
        id: String,
        includeGroups: String,
        limit: Int,
        offset: Int,
        nextURL: URL?,
        cacheMode: SpotifyRequestCacheMode
    ) async throws -> SpotifyAPIClient.SpotifyArtistAlbumsPage {
        return SpotifyAPIClient.SpotifyArtistAlbumsPage(items: [], next: nil)
    }

    func updatePlaylist(playlistID: String, name: String) async throws {}

    func currentUserPlaylists(limit: Int) async throws -> [SpotifyPlaylistSummary] {
        playlists
    }

    func playlistTracks(playlistID: String, limit: Int, maxPages: Int) async throws -> [SpotifyPlaylistTrackItem] {
        lastTracksLimit = limit
        lastTracksMaxPages = maxPages
        return tracks
    }

    func currentUserSavedTracks(limit: Int, maxPages: Int) async throws -> SpotifySavedTracksResult {
        SpotifySavedTracksResult(tracks: [], totalAvailable: 0)
    }
}

final class MockBrowsingAPI: SpotifyBrowsingAPI {
    private var playlistResults: [Result<[SpotifyPlaylistSummary], Error>]
    private var trackResults: [String: [Result<[SpotifyPlaylistTrackItem], Error>]]

    private let searchHandler: ((String, Int) async throws -> SpotifySearchResults)?
    private let artistAlbumsHandler: ((String, String, Int) async throws -> [SpotifyArtistAlbum])?
    private let artistAlbumsPageHandler: ((String, String, Int, Int, URL?) async throws -> SpotifyAPIClient.SpotifyArtistAlbumsPage)?
    private let albumTracksHandler: ((String, String?, Int) async throws -> [SpotifyTrack])?
    private let savedTracksResult: Result<SpotifySavedTracksResult, Error>?
    private let savedTracksHandler: (() async throws -> SpotifySavedTracksResult)?
    private let playlistsHandler: (() async throws -> [SpotifyPlaylistSummary])?
    private let updatePlaylistHandler: ((String, String) async throws -> Void)?
    private let profileHandler: (() async throws -> SpotifyUserProfile)?
    private(set) var savedTracksCallCount = 0
    private(set) var currentUserPlaylistsCallCount = 0
    private(set) var searchCallCount = 0
    private(set) var albumTracksCallCount = 0
    private(set) var artistAlbumsPageCallCount = 0
    private(set) var playlistTracksInvocationCountByID: [String: Int] = [:]
    private(set) var updatePlaylistCalls: [(playlistID: String, name: String)] = []
    var playlistTracksDelayOnInvocation: UInt64?

    init(
        playlistResults: [Result<[SpotifyPlaylistSummary], Error>],
        trackResults: [String: [Result<[SpotifyPlaylistTrackItem], Error>]],
        searchHandler: ((String, Int) async throws -> SpotifySearchResults)? = nil,
        artistAlbumsHandler: ((String, String, Int) async throws -> [SpotifyArtistAlbum])? = nil,
        artistAlbumsPageHandler: ((String, String, Int, Int, URL?) async throws -> SpotifyAPIClient.SpotifyArtistAlbumsPage)? = nil,
        albumTracksHandler: ((String, String?, Int) async throws -> [SpotifyTrack])? = nil,
        savedTracksResult: Result<SpotifySavedTracksResult, Error>? = nil,
        savedTracksHandler: (() async throws -> SpotifySavedTracksResult)? = nil,
        playlistsHandler: (() async throws -> [SpotifyPlaylistSummary])? = nil,
        updatePlaylistHandler: ((String, String) async throws -> Void)? = nil,
        profileHandler: (() async throws -> SpotifyUserProfile)? = nil
    ) {
        self.playlistResults = playlistResults
        self.trackResults = trackResults
        self.searchHandler = searchHandler
        self.artistAlbumsHandler = artistAlbumsHandler
        self.artistAlbumsPageHandler = artistAlbumsPageHandler
        self.albumTracksHandler = albumTracksHandler
        self.savedTracksResult = savedTracksResult
        self.savedTracksHandler = savedTracksHandler
        self.playlistsHandler = playlistsHandler
        self.updatePlaylistHandler = updatePlaylistHandler
        self.profileHandler = profileHandler
    }

    func updatePlaylist(playlistID: String, name: String) async throws {
        updatePlaylistCalls.append((playlistID: playlistID, name: name))
        try await updatePlaylistHandler?(playlistID, name)
    }

    func currentUserPlaylists(limit: Int) async throws -> [SpotifyPlaylistSummary] {
        currentUserPlaylistsCallCount += 1
        if let playlistsHandler {
            return try await playlistsHandler()
        }
        guard !playlistResults.isEmpty else { return [] }
        return try playlistResults.removeFirst().get()
    }

    func playlistTracks(playlistID: String, limit: Int, maxPages: Int) async throws -> [SpotifyPlaylistTrackItem] {
        if let playlistTracksDelayOnInvocation {
            try await Task.sleep(nanoseconds: playlistTracksDelayOnInvocation)
        }
        playlistTracksInvocationCountByID[playlistID, default: 0] += 1
        guard var results = trackResults[playlistID], !results.isEmpty else { return [] }
        let result = results.removeFirst()
        trackResults[playlistID] = results
        return try result.get()
    }

    func currentUserProfile() async throws -> SpotifyUserProfile {
        if let profileHandler {
            return try await profileHandler()
        }
        return SpotifyUserProfile(id: "u", displayName: nil, country: "US")
    }

    func artist(id: String, cacheMode: SpotifyRequestCacheMode) async throws -> SpotifyArtistDetail {
        SpotifyArtistDetail(id: id, name: "Artist \(id)", imageURL: nil, followersTotal: 1_000, genres: ["pop"], uri: "spotify:artist:\(id)")
    }

    func artistCached(id: String, cacheMode: SpotifyRequestCacheMode) async throws -> SpotifyAPIClient.CachedResponse<SpotifyArtistDetail> {
        SpotifyAPIClient.CachedResponse(
            value: try await artist(id: id, cacheMode: cacheMode),
            isStale: false
        )
    }

    func search(query: String, limit: Int) async throws -> SpotifySearchResults {
        searchCallCount += 1
        if let searchHandler {
            return try await searchHandler(query, limit)
        }
        return SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
    }

    func albumTracks(albumID: String, market: String?, limit: Int) async throws -> [SpotifyTrack] {
        albumTracksCallCount += 1
        if let albumTracksHandler {
            return try await albumTracksHandler(albumID, market, limit)
        }
        return []
    }

    func artistAlbumsCached(
        id: String,
        includeGroups: String,
        limit: Int,
        cacheMode: SpotifyRequestCacheMode
    ) async throws -> SpotifyAPIClient.CachedResponse<[SpotifyArtistAlbum]> {
        let albums: [SpotifyArtistAlbum]
        if let artistAlbumsHandler {
            albums = try await artistAlbumsHandler(id, includeGroups, limit)
        } else {
            albums = []
        }
        return SpotifyAPIClient.CachedResponse(value: albums, isStale: false)
    }

    func artistAlbumsPage(
        id: String,
        includeGroups: String,
        limit: Int,
        offset: Int,
        nextURL: URL?,
        cacheMode: SpotifyRequestCacheMode
    ) async throws -> SpotifyAPIClient.SpotifyArtistAlbumsPage {
        artistAlbumsPageCallCount += 1
        if let artistAlbumsPageHandler {
            return try await artistAlbumsPageHandler(id, includeGroups, limit, offset, nextURL)
        }
        let items: [SpotifyArtistAlbum]
        if let artistAlbumsHandler {
            items = try await artistAlbumsHandler(id, includeGroups, limit)
        } else {
            items = []
        }
        return SpotifyAPIClient.SpotifyArtistAlbumsPage(
            items: items,
            next: nil
        )
    }

    func currentUserSavedTracks(limit: Int, maxPages: Int) async throws -> SpotifySavedTracksResult {
        savedTracksCallCount += 1
        if let savedTracksHandler {
            return try await savedTracksHandler()
        }
        if let savedTracksResult {
            return try savedTracksResult.get()
        }
        return SpotifySavedTracksResult(tracks: [], totalAvailable: 0)
    }

    // MARK: - Home feed (set the handlers per test; default to empty results)

    var recentlyPlayedHandler: ((Int) async throws -> [SpotifyTrack])?
    var topTracksHandler: ((Int, String) async throws -> [SpotifyTrack])?
    private(set) var recentlyPlayedCallCount = 0
    private(set) var topTracksCallCount = 0

    func recentlyPlayedTracks(limit: Int) async throws -> [SpotifyTrack] {
        recentlyPlayedCallCount += 1
        if let recentlyPlayedHandler {
            return try await recentlyPlayedHandler(limit)
        }
        return []
    }

    func topTracks(limit: Int, timeRange: String) async throws -> [SpotifyTrack] {
        topTracksCallCount += 1
        if let topTracksHandler {
            return try await topTracksHandler(limit, timeRange)
        }
        return []
    }
}

final class MockBrowsingCache: SpotifyBrowsingCache {
    var cachedPlaylists: [SpotifyPlaylistSummary]?
    var cachedTracks: [String: [SpotifyPlaylistTrackItem]]
    /// Mirrors disk cache snapshot binding so `snapshotID` rotation invalidates track rows.
    private var trackSnapshotByPlaylistID: [String: String] = [:]
    /// Simulated age of the playlist list on disk; large values force `load()` to call `refreshPlaylists()` so tests exercise network refresh.
    var playlistListCacheAge: TimeInterval
    /// Track caches treated as TTL-expired by `loadTracks(...)` but still
    /// available to `loadTracksIgnoringAge(...)`.
    var expiredTrackIDs: Set<String>
    private(set) var savedPlaylists: [SpotifyPlaylistSummary]?
    private(set) var savedTracks: [String: [SpotifyPlaylistTrackItem]] = [:]

    init(
        cachedPlaylists: [SpotifyPlaylistSummary]? = nil,
        cachedTracks: [String: [SpotifyPlaylistTrackItem]] = [:],
        playlistListCacheAge: TimeInterval = 10_000,
        expiredTrackIDs: Set<String> = []
    ) {
        self.cachedPlaylists = cachedPlaylists
        self.cachedTracks = cachedTracks
        self.playlistListCacheAge = playlistListCacheAge
        self.expiredTrackIDs = expiredTrackIDs
        if let cachedPlaylists {
            for playlist in cachedPlaylists where cachedTracks[playlist.id] != nil {
                trackSnapshotByPlaylistID[playlist.id] = playlist.snapshotID
            }
        }
    }

    func loadPlaylistsBundle(now: Date) throws -> (playlists: [SpotifyPlaylistSummary], age: TimeInterval)? {
        guard let playlists = cachedPlaylists, !playlists.isEmpty else { return nil }
        return (playlists, playlistListCacheAge)
    }

    func savePlaylists(_ playlists: [SpotifyPlaylistSummary], cachedAt: Date) throws {
        savedPlaylists = playlists
        cachedPlaylists = playlists
    }

    func loadTracks(playlistID: String, snapshotID: String, now: Date, maxAge: TimeInterval) throws -> [SpotifyPlaylistTrackItem]? {
        if expiredTrackIDs.contains(playlistID) {
            return nil
        }
        // When no snapshot was seeded (tracks-only tests), accept any requested snapshot.
        if let bound = trackSnapshotByPlaylistID[playlistID], bound != snapshotID {
            return nil
        }
        return cachedTracks[playlistID]
    }

    func loadTracksIgnoringAge(playlistID: String, snapshotID: String) throws -> [SpotifyPlaylistTrackItem]? {
        if let bound = trackSnapshotByPlaylistID[playlistID], bound != snapshotID {
            return nil
        }
        return cachedTracks[playlistID]
    }

    func saveTracks(_ tracks: [SpotifyPlaylistTrackItem], playlistID: String, snapshotID: String, cachedAt: Date) throws {
        savedTracks[playlistID] = tracks
        cachedTracks[playlistID] = tracks
        trackSnapshotByPlaylistID[playlistID] = snapshotID
    }

    func invalidateTracks(playlistID: String) throws {
        cachedTracks[playlistID] = nil
        trackSnapshotByPlaylistID[playlistID] = nil
    }
}
