import Foundation
@testable import Spotiglass

final class LimitCapturingBrowsingAPI: MusicBrowsingProvider {
    let playlists: [MusicPlaylistSummary]
    let tracks: [MusicPlaylistTrackItem]
    private(set) var lastTracksLimit: Int?
    private(set) var lastTracksMaxPages: Int?

    init(playlists: [MusicPlaylistSummary], tracks: [MusicPlaylistTrackItem]) {
        self.playlists = playlists
        self.tracks = tracks
    }

    func currentUserProfile() async throws -> MusicUserProfile {
        MusicUserProfile(id: "u", displayName: nil, country: "US")
    }

    func artist(id: String, cacheMode: MusicRequestCacheMode) async throws -> MusicArtistDetail {
        MusicArtistDetail(id: id, name: "Artist \(id)", imageURL: nil, followersTotal: nil, genres: [], uri: "spotify:artist:\(id)")
    }

    func artistCached(id: String, cacheMode: MusicRequestCacheMode) async throws -> MusicCachedResponse<MusicArtistDetail> {
        MusicCachedResponse(
            value: try await artist(id: id, cacheMode: cacheMode),
            isStale: false
        )
    }

    func search(query: String, limit: Int) async throws -> MusicSearchResults {
        MusicSearchResults(tracks: [], artists: [], albums: [], playlists: [])
    }

    func albumTracks(albumID: String, market: String?, limit: Int) async throws -> [MusicTrack] {
        []
    }

    func artistAlbumsCached(
        id: String,
        includeGroups: [MusicArtistAlbumGroup],
        limit: Int,
        cacheMode: MusicRequestCacheMode
    ) async throws -> MusicCachedResponse<[MusicArtistAlbum]> {
        MusicCachedResponse(value: [], isStale: false)
    }

    func artistAlbumsPage(
        id: String,
        includeGroups: [MusicArtistAlbumGroup],
        limit: Int,
        offset: Int,
        nextURL: URL?,
        cacheMode: MusicRequestCacheMode
    ) async throws -> MusicArtistAlbumsPage {
        return MusicArtistAlbumsPage(items: [], next: nil)
    }

    func updatePlaylist(playlistID: String, name: String) async throws {}

    func currentUserPlaylists(limit: Int) async throws -> [MusicPlaylistSummary] {
        playlists
    }

    func playlistTracks(playlistID: String, limit: Int, maxPages: Int) async throws -> [MusicPlaylistTrackItem] {
        lastTracksLimit = limit
        lastTracksMaxPages = maxPages
        return tracks
    }

    func currentUserSavedTracks(limit: Int, maxPages: Int?) async throws -> MusicSavedTracksResult {
        MusicSavedTracksResult(tracks: [], totalAvailable: 0)
    }
}

final class MockBrowsingAPI: MusicBrowsingProvider {
    private var playlistResults: [Result<[MusicPlaylistSummary], Error>]
    private var trackResults: [String: [Result<[MusicPlaylistTrackItem], Error>]]

    private let searchHandler: ((String, Int) async throws -> MusicSearchResults)?
    private let artistAlbumsHandler: ((String, String, Int) async throws -> [MusicArtistAlbum])?
    private let artistAlbumsPageHandler: ((String, String, Int, Int, URL?) async throws -> MusicArtistAlbumsPage)?
    private let albumTracksHandler: ((String, String?, Int) async throws -> [MusicTrack])?
    private let savedTracksResult: Result<MusicSavedTracksResult, Error>?
    private let savedTracksHandler: (() async throws -> MusicSavedTracksResult)?
    private let playlistsHandler: (() async throws -> [MusicPlaylistSummary])?
    private let updatePlaylistHandler: ((String, String) async throws -> Void)?
    private let addTracksHandler: ((String, [String]) async throws -> Void)?
    private let removeTracksHandler: ((String, [MusicPlaylistTrackRemoval], String?) async throws -> Void)?
    private let saveTracksHandler: (([String]) async throws -> Void)?
    private let removeSavedTracksHandler: (([String]) async throws -> Void)?
    private let savedTrackStatusesHandler: (([String]) async throws -> [Bool])?
    private let profileHandler: (() async throws -> MusicUserProfile)?
    private(set) var savedTracksCallCount = 0
    private(set) var currentUserPlaylistsCallCount = 0
    private(set) var searchCallCount = 0
    private(set) var albumTracksCallCount = 0
    private(set) var artistAlbumsPageCallCount = 0
    private(set) var playlistTracksInvocationCountByID: [String: Int] = [:]
    private(set) var updatePlaylistCalls: [(playlistID: String, name: String)] = []
    private(set) var addTracksCalls: [(playlistID: String, uris: [String])] = []
    private(set) var removeTracksCalls: [(playlistID: String, items: [MusicPlaylistTrackRemoval], snapshotID: String?)] = []
    private(set) var saveTracksCalls: [[String]] = []
    private(set) var removeSavedTracksCalls: [[String]] = []
    private(set) var savedTrackStatusesCalls: [[String]] = []
    var playlistTracksDelayOnInvocation: UInt64?
    var onPlaylistTracksInvocation: ((String) -> Void)?
    var onCurrentUserPlaylistsInvocation: (() async -> Void)?

    init(
        playlistResults: [Result<[MusicPlaylistSummary], Error>],
        trackResults: [String: [Result<[MusicPlaylistTrackItem], Error>]],
        searchHandler: ((String, Int) async throws -> MusicSearchResults)? = nil,
        artistAlbumsHandler: ((String, String, Int) async throws -> [MusicArtistAlbum])? = nil,
        artistAlbumsPageHandler: ((String, String, Int, Int, URL?) async throws -> MusicArtistAlbumsPage)? = nil,
        albumTracksHandler: ((String, String?, Int) async throws -> [MusicTrack])? = nil,
        savedTracksResult: Result<MusicSavedTracksResult, Error>? = nil,
        savedTracksHandler: (() async throws -> MusicSavedTracksResult)? = nil,
        playlistsHandler: (() async throws -> [MusicPlaylistSummary])? = nil,
        updatePlaylistHandler: ((String, String) async throws -> Void)? = nil,
        addTracksHandler: ((String, [String]) async throws -> Void)? = nil,
        removeTracksHandler: ((String, [MusicPlaylistTrackRemoval], String?) async throws -> Void)? = nil,
        saveTracksHandler: (([String]) async throws -> Void)? = nil,
        removeSavedTracksHandler: (([String]) async throws -> Void)? = nil,
        savedTrackStatusesHandler: (([String]) async throws -> [Bool])? = nil,
        profileHandler: (() async throws -> MusicUserProfile)? = nil
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
        self.addTracksHandler = addTracksHandler
        self.removeTracksHandler = removeTracksHandler
        self.saveTracksHandler = saveTracksHandler
        self.removeSavedTracksHandler = removeSavedTracksHandler
        self.savedTrackStatusesHandler = savedTrackStatusesHandler
        self.profileHandler = profileHandler
    }

    func updatePlaylist(playlistID: String, name: String) async throws {
        updatePlaylistCalls.append((playlistID: playlistID, name: name))
        try await updatePlaylistHandler?(playlistID, name)
    }

    func addTracksToPlaylist(playlistID: String, uris: [String]) async throws {
        addTracksCalls.append((playlistID: playlistID, uris: uris))
        try await addTracksHandler?(playlistID, uris)
    }

    func removeTracksFromPlaylist(
        playlistID: String,
        items: [MusicPlaylistTrackRemoval],
        snapshotID: String?
    ) async throws {
        removeTracksCalls.append((playlistID: playlistID, items: items, snapshotID: snapshotID))
        try await removeTracksHandler?(playlistID, items, snapshotID)
    }

    func saveTracks(ids: [String]) async throws {
        saveTracksCalls.append(ids)
        try await saveTracksHandler?(ids)
    }

    func removeSavedTracks(ids: [String]) async throws {
        removeSavedTracksCalls.append(ids)
        try await removeSavedTracksHandler?(ids)
    }

    func savedTrackStatuses(ids: [String]) async throws -> [Bool] {
        savedTrackStatusesCalls.append(ids)
        if let savedTrackStatusesHandler {
            return try await savedTrackStatusesHandler(ids)
        }
        return Array(repeating: false, count: ids.count)
    }

    func currentUserPlaylists(limit: Int) async throws -> [MusicPlaylistSummary] {
        currentUserPlaylistsCallCount += 1
        await onCurrentUserPlaylistsInvocation?()
        if let playlistsHandler {
            return try await playlistsHandler()
        }
        guard !playlistResults.isEmpty else { return [] }
        return try playlistResults.removeFirst().get()
    }

    func playlistTracks(playlistID: String, limit: Int, maxPages: Int) async throws -> [MusicPlaylistTrackItem] {
        onPlaylistTracksInvocation?(playlistID)
        if let playlistTracksDelayOnInvocation {
            try await Task.sleep(nanoseconds: playlistTracksDelayOnInvocation)
        }
        playlistTracksInvocationCountByID[playlistID, default: 0] += 1
        guard var results = trackResults[playlistID], !results.isEmpty else { return [] }
        let result = results.removeFirst()
        trackResults[playlistID] = results
        return try result.get()
    }

    func currentUserProfile() async throws -> MusicUserProfile {
        if let profileHandler {
            return try await profileHandler()
        }
        return MusicUserProfile(id: "u", displayName: nil, country: "US")
    }

    func artist(id: String, cacheMode: MusicRequestCacheMode) async throws -> MusicArtistDetail {
        MusicArtistDetail(id: id, name: "Artist \(id)", imageURL: nil, followersTotal: 1_000, genres: ["pop"], uri: "spotify:artist:\(id)")
    }

    func artistCached(id: String, cacheMode: MusicRequestCacheMode) async throws -> MusicCachedResponse<MusicArtistDetail> {
        MusicCachedResponse(
            value: try await artist(id: id, cacheMode: cacheMode),
            isStale: false
        )
    }

    func search(query: String, limit: Int) async throws -> MusicSearchResults {
        searchCallCount += 1
        if let searchHandler {
            return try await searchHandler(query, limit)
        }
        return MusicSearchResults(tracks: [], artists: [], albums: [], playlists: [])
    }

    func albumTracks(albumID: String, market: String?, limit: Int) async throws -> [MusicTrack] {
        albumTracksCallCount += 1
        if let albumTracksHandler {
            return try await albumTracksHandler(albumID, market, limit)
        }
        return []
    }

    func artistAlbumsCached(
        id: String,
        includeGroups: [MusicArtistAlbumGroup],
        limit: Int,
        cacheMode: MusicRequestCacheMode
    ) async throws -> MusicCachedResponse<[MusicArtistAlbum]> {
        let albums: [MusicArtistAlbum]
        if let artistAlbumsHandler {
            albums = try await artistAlbumsHandler(id, SpotifyAPIClient.includeGroupsQueryValue(includeGroups), limit)
        } else {
            albums = []
        }
        return MusicCachedResponse(value: albums, isStale: false)
    }

    func artistAlbumsPage(
        id: String,
        includeGroups: [MusicArtistAlbumGroup],
        limit: Int,
        offset: Int,
        nextURL: URL?,
        cacheMode: MusicRequestCacheMode
    ) async throws -> MusicArtistAlbumsPage {
        artistAlbumsPageCallCount += 1
        if let artistAlbumsPageHandler {
            return try await artistAlbumsPageHandler(id, SpotifyAPIClient.includeGroupsQueryValue(includeGroups), limit, offset, nextURL)
        }
        let items: [MusicArtistAlbum]
        if let artistAlbumsHandler {
            items = try await artistAlbumsHandler(id, SpotifyAPIClient.includeGroupsQueryValue(includeGroups), limit)
        } else {
            items = []
        }
        return MusicArtistAlbumsPage(
            items: items,
            next: nil
        )
    }

    func currentUserSavedTracks(limit: Int, maxPages: Int?) async throws -> MusicSavedTracksResult {
        savedTracksCallCount += 1
        if let savedTracksHandler {
            return try await savedTracksHandler()
        }
        if let savedTracksResult {
            return try savedTracksResult.get()
        }
        return MusicSavedTracksResult(tracks: [], totalAvailable: 0)
    }

    // MARK: - Home feed (set the handlers per test; default to empty results)

    var recentlyPlayedHandler: ((Int) async throws -> [MusicTrack])?
    var topTracksHandler: ((Int, String) async throws -> [MusicTrack])?
    private(set) var recentlyPlayedCallCount = 0
    private(set) var recentlyPlayedCacheModes: [MusicRequestCacheMode] = []
    private(set) var topTracksCallCount = 0
    private(set) var topTracksCacheModes: [MusicRequestCacheMode] = []
    var topArtistsHandler: ((Int, String) async throws -> [MusicArtist])?
    var followedArtistsHandler: ((Int, Int?) async throws -> [MusicArtist])?
    var artistTopTracksHandler: ((String, String?) async throws -> [MusicTrack])?
    private(set) var topArtistsCallCount = 0
    private(set) var followedArtistsCallCount = 0
    private(set) var artistTopTracksCallCount = 0
    private(set) var artistTopTracksRequestedIDs: [String] = []

    func recentlyPlayedTracks(
        limit: Int,
        cacheMode: MusicRequestCacheMode
    ) async throws -> [MusicTrack] {
        recentlyPlayedCallCount += 1
        recentlyPlayedCacheModes.append(cacheMode)
        if let recentlyPlayedHandler {
            return try await recentlyPlayedHandler(limit)
        }
        return []
    }

    func topTracks(
        limit: Int,
        timeRange: MusicTopItemsTimeRange,
        cacheMode: MusicRequestCacheMode
    ) async throws -> [MusicTrack] {
        topTracksCallCount += 1
        topTracksCacheModes.append(cacheMode)
        if let topTracksHandler {
            return try await topTracksHandler(limit, timeRange.rawValue)
        }
        return []
    }

    func topArtists(
        limit: Int,
        timeRange: MusicTopItemsTimeRange,
        cacheMode: MusicRequestCacheMode
    ) async throws -> [MusicArtist] {
        topArtistsCallCount += 1
        if let topArtistsHandler {
            return try await topArtistsHandler(limit, timeRange.rawValue)
        }
        return []
    }

    func followedArtists(limit: Int, maxPages: Int?) async throws -> [MusicArtist] {
        followedArtistsCallCount += 1
        if let followedArtistsHandler {
            return try await followedArtistsHandler(limit, maxPages)
        }
        return []
    }

    func artistTopTracks(
        id: String,
        market: String?,
        cacheMode: MusicRequestCacheMode
    ) async throws -> [MusicTrack] {
        artistTopTracksCallCount += 1
        artistTopTracksRequestedIDs.append(id)
        if let artistTopTracksHandler {
            return try await artistTopTracksHandler(id, market)
        }
        return []
    }
}

final class MockBrowsingCache: SpotifyBrowsingCache {
    var cachedPlaylists: [MusicPlaylistSummary]?
    var cachedTracks: [String: [MusicPlaylistTrackItem]]
    /// Mirrors disk cache snapshot binding so `snapshotID` rotation invalidates track rows.
    private var trackSnapshotByPlaylistID: [String: String] = [:]
    /// Simulated age of the playlist list on disk; large values force `load()` to call `refreshPlaylists()` so tests exercise network refresh.
    var playlistListCacheAge: TimeInterval
    /// Track caches treated as TTL-expired by `loadTracks(...)` but still
    /// available to `loadTracksIgnoringAge(...)`.
    var expiredTrackIDs: Set<String>
    private(set) var savedPlaylists: [MusicPlaylistSummary]?
    private(set) var savedTracks: [String: [MusicPlaylistTrackItem]] = [:]
    /// Records every `invalidateTracks` call, since a reload immediately
    /// repopulates the cache and would otherwise hide the invalidation.
    private(set) var invalidatedTrackPlaylistIDs: [String] = []
    var cachedLibraryContinuation: LibraryContinuationLibrary?
    private(set) var savedLibraryContinuation: LibraryContinuationLibrary?

    init(
        cachedPlaylists: [MusicPlaylistSummary]? = nil,
        cachedTracks: [String: [MusicPlaylistTrackItem]] = [:],
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

    func loadPlaylistsBundle(now: Date) throws -> (playlists: [MusicPlaylistSummary], age: TimeInterval)? {
        guard let playlists = cachedPlaylists, !playlists.isEmpty else { return nil }
        return (playlists, playlistListCacheAge)
    }

    func savePlaylists(_ playlists: [MusicPlaylistSummary], cachedAt: Date) throws {
        savedPlaylists = playlists
        cachedPlaylists = playlists
    }

    func loadTracks(playlistID: String, snapshotID: String, now: Date, maxAge: TimeInterval) throws -> [MusicPlaylistTrackItem]? {
        if expiredTrackIDs.contains(playlistID) {
            return nil
        }
        // When no snapshot was seeded (tracks-only tests), accept any requested snapshot.
        if let bound = trackSnapshotByPlaylistID[playlistID], bound != snapshotID {
            return nil
        }
        return cachedTracks[playlistID]
    }

    func loadTracksIgnoringAge(playlistID: String, snapshotID: String) throws -> [MusicPlaylistTrackItem]? {
        if let bound = trackSnapshotByPlaylistID[playlistID], bound != snapshotID {
            return nil
        }
        return cachedTracks[playlistID]
    }

    func saveTracks(_ tracks: [MusicPlaylistTrackItem], playlistID: String, snapshotID: String, cachedAt: Date) throws {
        savedTracks[playlistID] = tracks
        cachedTracks[playlistID] = tracks
        trackSnapshotByPlaylistID[playlistID] = snapshotID
    }

    func invalidateTracks(playlistID: String) throws {
        invalidatedTrackPlaylistIDs.append(playlistID)
        cachedTracks[playlistID] = nil
        trackSnapshotByPlaylistID[playlistID] = nil
    }

    func loadLibraryContinuationIndex(now: Date, maxAge: TimeInterval) throws -> LibraryContinuationLibrary? {
        cachedLibraryContinuation
    }

    func loadLibraryContinuationIndexIgnoringAge() throws -> LibraryContinuationLibrary? {
        cachedLibraryContinuation
    }

    func saveLibraryContinuationIndex(_ library: LibraryContinuationLibrary, cachedAt: Date) throws {
        savedLibraryContinuation = library
        cachedLibraryContinuation = library
    }

    func invalidateLibraryContinuationIndex() throws {
        cachedLibraryContinuation = nil
    }
}
