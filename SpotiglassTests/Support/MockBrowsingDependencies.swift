import Foundation
@testable import Spotiglass

final class LimitCapturingBrowsingAPI: MusicBrowsingProvider {
    let playlists: [MusicPlaylistSummary]
    let tracks: [MusicPlaylistTrackItem]
    private let lock = NSLock()
    private var recordedTracksLimit: Int?
    private var recordedTracksMaxPages: Int?
    var lastTracksLimit: Int? { lock.withLock { recordedTracksLimit } }
    var lastTracksMaxPages: Int? { lock.withLock { recordedTracksMaxPages } }

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
        lock.withLock {
            recordedTracksLimit = limit
            recordedTracksMaxPages = maxPages
        }
        return tracks
    }

    func currentUserSavedTracks(limit: Int, maxPages: Int?) async throws -> MusicSavedTracksResult {
        MusicSavedTracksResult(tracks: [], totalAvailable: 0)
    }
}

final class MockBrowsingAPI: MusicBrowsingProvider {
    // The view model calls this API from background tasks (home feed loads,
    // concurrent refreshes) while tests read the call log on the main thread,
    // so every piece of mutable state lives in `state` and goes through `lock`.
    // Unlocked counters raced two concurrent home feed loads under Thread
    // Sanitizer in `testConcurrentPlaylistRefreshesShareSingleInFlightRequest`.
    private struct State {
        var playlistResults: [Result<[MusicPlaylistSummary], Error>]
        var trackResults: [String: [Result<[MusicPlaylistTrackItem], Error>]]
        var savedTracksCallCount = 0
        var currentUserPlaylistsCallCount = 0
        var searchCallCount = 0
        var albumTracksCallCount = 0
        var artistAlbumsPageCallCount = 0
        var playlistTracksInvocationCountByID: [String: Int] = [:]
        var lastReadTracksByID: [String: [MusicPlaylistTrackItem]] = [:]
        var lastReadHolds: [String: AsyncSignal] = [:]
        var onLastRead: ((String) -> Void)?
        var playlistTracksHold: AsyncSignal?
        var updatePlaylistCalls: [(playlistID: String, name: String)] = []
        var addTracksCalls: [(playlistID: String, uris: [String])] = []
        var removeTracksCalls: [(playlistID: String, items: [MusicPlaylistTrackRemoval], snapshotID: String?)] = []
        var saveTracksCalls: [[String]] = []
        var removeSavedTracksCalls: [[String]] = []
        var savedTrackStatusesCalls: [[String]] = []
        var onPlaylistTracksInvocation: ((String) -> Void)?
        var onCurrentUserPlaylistsInvocation: (() async -> Void)?
        var recentlyPlayedHandler: ((Int) async throws -> [MusicTrack])?
        var topTracksHandler: ((Int, String) async throws -> [MusicTrack])?
        var topArtistsHandler: ((Int, String) async throws -> [MusicArtist])?
        var followedArtistsHandler: ((Int, Int?) async throws -> [MusicArtist])?
        var artistTopTracksHandler: ((String, String?) async throws -> [MusicTrack])?
        var recentlyPlayedCallCount = 0
        var recentlyPlayedCacheModes: [MusicRequestCacheMode] = []
        var topTracksCallCount = 0
        var topTracksCacheModes: [MusicRequestCacheMode] = []
        var topArtistsCallCount = 0
        var followedArtistsCallCount = 0
        var artistTopTracksCallCount = 0
        var artistTopTracksRequestedIDs: [String] = []
    }

    private let lock = NSLock()
    private var state: State

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

    var savedTracksCallCount: Int { locked { $0.savedTracksCallCount } }
    var currentUserPlaylistsCallCount: Int { locked { $0.currentUserPlaylistsCallCount } }
    var searchCallCount: Int { locked { $0.searchCallCount } }
    var albumTracksCallCount: Int { locked { $0.albumTracksCallCount } }
    var artistAlbumsPageCallCount: Int { locked { $0.artistAlbumsPageCallCount } }
    var playlistTracksInvocationCountByID: [String: Int] { locked { $0.playlistTracksInvocationCountByID } }
    var updatePlaylistCalls: [(playlistID: String, name: String)] { locked { $0.updatePlaylistCalls } }
    var addTracksCalls: [(playlistID: String, uris: [String])] { locked { $0.addTracksCalls } }
    var removeTracksCalls: [(playlistID: String, items: [MusicPlaylistTrackRemoval], snapshotID: String?)] {
        locked { $0.removeTracksCalls }
    }
    var saveTracksCalls: [[String]] { locked { $0.saveTracksCalls } }
    var removeSavedTracksCalls: [[String]] { locked { $0.removeSavedTracksCalls } }
    var savedTrackStatusesCalls: [[String]] { locked { $0.savedTrackStatusesCalls } }
    var onPlaylistTracksInvocation: ((String) -> Void)? {
        get { locked { $0.onPlaylistTracksInvocation } }
        set { locked { $0.onPlaylistTracksInvocation = newValue } }
    }
    var onCurrentUserPlaylistsInvocation: (() async -> Void)? {
        get { locked { $0.onCurrentUserPlaylistsInvocation } }
        set { locked { $0.onCurrentUserPlaylistsInvocation = newValue } }
    }

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
        self.state = State(playlistResults: playlistResults, trackResults: trackResults)
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

    private func locked<T>(_ body: (inout State) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }

    func updatePlaylist(playlistID: String, name: String) async throws {
        locked { $0.updatePlaylistCalls.append((playlistID: playlistID, name: name)) }
        try await updatePlaylistHandler?(playlistID, name)
    }

    func addTracksToPlaylist(playlistID: String, uris: [String]) async throws {
        locked { $0.addTracksCalls.append((playlistID: playlistID, uris: uris)) }
        try await addTracksHandler?(playlistID, uris)
    }

    func removeTracksFromPlaylist(
        playlistID: String,
        items: [MusicPlaylistTrackRemoval],
        snapshotID: String?
    ) async throws {
        locked { $0.removeTracksCalls.append((playlistID: playlistID, items: items, snapshotID: snapshotID)) }
        try await removeTracksHandler?(playlistID, items, snapshotID)
    }

    func saveTracks(ids: [String]) async throws {
        locked { $0.saveTracksCalls.append(ids) }
        try await saveTracksHandler?(ids)
    }

    func removeSavedTracks(ids: [String]) async throws {
        locked { $0.removeSavedTracksCalls.append(ids) }
        try await removeSavedTracksHandler?(ids)
    }

    func savedTrackStatuses(ids: [String]) async throws -> [Bool] {
        locked { $0.savedTrackStatusesCalls.append(ids) }
        if let savedTrackStatusesHandler {
            return try await savedTrackStatusesHandler(ids)
        }
        return Array(repeating: false, count: ids.count)
    }

    func currentUserPlaylists(limit: Int) async throws -> [MusicPlaylistSummary] {
        let onInvocation = locked { state -> (() async -> Void)? in
            state.currentUserPlaylistsCallCount += 1
            return state.onCurrentUserPlaylistsInvocation
        }
        await onInvocation?()
        if let playlistsHandler {
            return try await playlistsHandler()
        }
        let next = locked { state in
            state.playlistResults.isEmpty ? nil : state.playlistResults.removeFirst()
        }
        return try next?.get() ?? []
    }

    func playlistTracks(playlistID: String, limit: Int, maxPages: Int) async throws -> [MusicPlaylistTrackItem] {
        let (onInvocation, hold) = locked { ($0.onPlaylistTracksInvocation, $0.playlistTracksHold) }
        onInvocation?(playlistID)
        if let hold {
            // A held read ends early when its task is cancelled, like a network read.
            await hold.wait()
            try Task.checkCancellation()
        }
        let result = locked { state -> Result<[MusicPlaylistTrackItem], Error>? in
            state.playlistTracksInvocationCountByID[playlistID, default: 0] += 1
            guard var results = state.trackResults[playlistID], !results.isEmpty else { return nil }
            let result = results.removeFirst()
            state.trackResults[playlistID] = results
            return result
        }
        return try result?.get() ?? []
    }

    /// What `lastReadPlaylistTracks` answers, by playlist ID.
    var lastReadTracksByID: [String: [MusicPlaylistTrackItem]] {
        get { locked { $0.lastReadTracksByID } }
        set { locked { $0.lastReadTracksByID = newValue } }
    }

    /// Holds `playlistTracks` until the signal fires, after `onPlaylistTracksInvocation` ran.
    var playlistTracksHold: AsyncSignal? {
        get { locked { $0.playlistTracksHold } }
        set { locked { $0.playlistTracksHold = newValue } }
    }

    /// Holds `lastReadPlaylistTracks` for a playlist until its signal fires.
    var lastReadHolds: [String: AsyncSignal] {
        get { locked { $0.lastReadHolds } }
        set { locked { $0.lastReadHolds = newValue } }
    }

    /// Runs when `lastReadPlaylistTracks` is asked, with the playlist ID.
    var onLastRead: ((String) -> Void)? {
        get { locked { $0.onLastRead } }
        set { locked { $0.onLastRead = newValue } }
    }

    func lastReadPlaylistTracks(playlistID: String) async -> [MusicPlaylistTrackItem]? {
        let (onLastRead, hold) = locked { ($0.onLastRead, $0.lastReadHolds[playlistID]) }
        onLastRead?(playlistID)
        if let hold {
            // Like MusicKit's reads, the wait doesn't end when the caller's task is cancelled.
            await Task.detached { await hold.wait() }.value
        }
        return locked { $0.lastReadTracksByID[playlistID] }
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
        locked { $0.searchCallCount += 1 }
        if let searchHandler {
            return try await searchHandler(query, limit)
        }
        return MusicSearchResults(tracks: [], artists: [], albums: [], playlists: [])
    }

    func albumTracks(albumID: String, market: String?, limit: Int) async throws -> [MusicTrack] {
        locked { $0.albumTracksCallCount += 1 }
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
        locked { $0.artistAlbumsPageCallCount += 1 }
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
        locked { $0.savedTracksCallCount += 1 }
        if let savedTracksHandler {
            return try await savedTracksHandler()
        }
        if let savedTracksResult {
            return try savedTracksResult.get()
        }
        return MusicSavedTracksResult(tracks: [], totalAvailable: 0)
    }

    // MARK: - Home feed (set the handlers per test; default to empty results)

    var recentlyPlayedHandler: ((Int) async throws -> [MusicTrack])? {
        get { locked { $0.recentlyPlayedHandler } }
        set { locked { $0.recentlyPlayedHandler = newValue } }
    }
    var topTracksHandler: ((Int, String) async throws -> [MusicTrack])? {
        get { locked { $0.topTracksHandler } }
        set { locked { $0.topTracksHandler = newValue } }
    }
    var topArtistsHandler: ((Int, String) async throws -> [MusicArtist])? {
        get { locked { $0.topArtistsHandler } }
        set { locked { $0.topArtistsHandler = newValue } }
    }
    var followedArtistsHandler: ((Int, Int?) async throws -> [MusicArtist])? {
        get { locked { $0.followedArtistsHandler } }
        set { locked { $0.followedArtistsHandler = newValue } }
    }
    var artistTopTracksHandler: ((String, String?) async throws -> [MusicTrack])? {
        get { locked { $0.artistTopTracksHandler } }
        set { locked { $0.artistTopTracksHandler = newValue } }
    }
    var recentlyPlayedCallCount: Int { locked { $0.recentlyPlayedCallCount } }
    var recentlyPlayedCacheModes: [MusicRequestCacheMode] { locked { $0.recentlyPlayedCacheModes } }
    var topTracksCallCount: Int { locked { $0.topTracksCallCount } }
    var topTracksCacheModes: [MusicRequestCacheMode] { locked { $0.topTracksCacheModes } }
    var topArtistsCallCount: Int { locked { $0.topArtistsCallCount } }
    var followedArtistsCallCount: Int { locked { $0.followedArtistsCallCount } }
    var artistTopTracksCallCount: Int { locked { $0.artistTopTracksCallCount } }
    var artistTopTracksRequestedIDs: [String] { locked { $0.artistTopTracksRequestedIDs } }

    func recentlyPlayedTracks(
        limit: Int,
        cacheMode: MusicRequestCacheMode
    ) async throws -> [MusicTrack] {
        let handler = locked { state -> ((Int) async throws -> [MusicTrack])? in
            state.recentlyPlayedCallCount += 1
            state.recentlyPlayedCacheModes.append(cacheMode)
            return state.recentlyPlayedHandler
        }
        if let handler {
            return try await handler(limit)
        }
        return []
    }

    func topTracks(
        limit: Int,
        timeRange: MusicTopItemsTimeRange,
        cacheMode: MusicRequestCacheMode
    ) async throws -> [MusicTrack] {
        let handler = locked { state -> ((Int, String) async throws -> [MusicTrack])? in
            state.topTracksCallCount += 1
            state.topTracksCacheModes.append(cacheMode)
            return state.topTracksHandler
        }
        if let handler {
            return try await handler(limit, timeRange.rawValue)
        }
        return []
    }

    func topArtists(
        limit: Int,
        timeRange: MusicTopItemsTimeRange,
        cacheMode: MusicRequestCacheMode
    ) async throws -> [MusicArtist] {
        let handler = locked { state -> ((Int, String) async throws -> [MusicArtist])? in
            state.topArtistsCallCount += 1
            return state.topArtistsHandler
        }
        if let handler {
            return try await handler(limit, timeRange.rawValue)
        }
        return []
    }

    func followedArtists(limit: Int, maxPages: Int?) async throws -> [MusicArtist] {
        let handler = locked { state -> ((Int, Int?) async throws -> [MusicArtist])? in
            state.followedArtistsCallCount += 1
            return state.followedArtistsHandler
        }
        if let handler {
            return try await handler(limit, maxPages)
        }
        return []
    }

    func artistTopTracks(
        id: String,
        market: String?,
        cacheMode: MusicRequestCacheMode
    ) async throws -> [MusicTrack] {
        let handler = locked { state -> ((String, String?) async throws -> [MusicTrack])? in
            state.artistTopTracksCallCount += 1
            state.artistTopTracksRequestedIDs.append(id)
            return state.artistTopTracksHandler
        }
        if let handler {
            return try await handler(id, market)
        }
        return []
    }
}

final class MockBrowsingCache: MusicBrowsingCache {
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
