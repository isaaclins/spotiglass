import Foundation

enum SpotiglassSidebarLibrary {
    /// Synthetic ID for Liked Songs: disk cache, `List` tags, and `PlaybackSessionViewModel.activePlaylistID`.
    static let likedSongsVirtualPlaylistID = "spotiglass.likedSongs"
    static let likedSongsCacheSnapshotID = "saved-tracks"
}

enum SidebarSelection: Hashable {
    case home
    case likedSongs
    case playlist(String)
    /// Pinned-area row identified by ``PinnedItem.id``. The browser view
    /// routes the click through ``PinnedItemsStore`` to dispatch the right
    /// detail loader (or playback for pinned tracks).
    case pinnedItem(String)
}

private enum BrowserNavigationTarget: Equatable {
    case sidebar(SidebarSelection)
    case artist(String)
    case album(id: String, title: String, subtitle: String, artworkURL: URL?)
}

/// Logical drill-in path shown in the window toolbar (separate from ``backNavigationStack``).
struct BrowserBreadcrumb: Equatable, Identifiable {
    enum Kind: Equatable {
        case likedSongs
        case playlist(id: String)
        case artist(id: String)
        case album(id: String, title: String, subtitle: String, artworkURL: URL?)
    }

    let id: UUID
    let label: String
    let systemImage: String
    let kind: Kind
}

enum BrowserNavigationOrigin {
    /// New navigation started from sidebar, palette, pins, or lyrics overlay — replaces the trail root.
    case reset
    /// In-page drill-in (track artist tap, album card, related artist) — appends one segment.
    case extend
    /// Replay navigation without mutating ``breadcrumbPath`` (back button, crumb tap, refresh-in-place).
    case backStackReplay
}

enum PlaylistRefreshTrigger {
    case automatic
    case userInitiated
}

protocol SpotifyBrowsingAPI {
    func currentUserPlaylists(limit: Int) async throws -> [SpotifyPlaylistSummary]
    func playlistTracks(playlistID: String, limit: Int, maxPages: Int) async throws -> [SpotifyPlaylistTrackItem]
    func currentUserSavedTracks(limit: Int, maxPages: Int) async throws -> SpotifySavedTracksResult
    func currentUserProfile() async throws -> SpotifyUserProfile
    func artist(id: String) async throws -> SpotifyArtistDetail
    func artist(id: String, cacheMode: SpotifyRequestCacheMode) async throws -> SpotifyArtistDetail
    func artistCached(id: String, cacheMode: SpotifyRequestCacheMode) async throws -> SpotifyAPIClient.CachedResponse<SpotifyArtistDetail>
    func artistTopTracks(id: String, market: String?) async throws -> [SpotifyTrack]
    func artistAlbums(id: String, includeGroups: String, limit: Int, cacheMode: SpotifyRequestCacheMode) async throws -> [SpotifyArtistAlbum]
    func artistAlbumsCached(
        id: String,
        includeGroups: String,
        limit: Int,
        cacheMode: SpotifyRequestCacheMode
    ) async throws -> SpotifyAPIClient.CachedResponse<[SpotifyArtistAlbum]>
    func artistAlbumsPage(
        id: String,
        includeGroups: String,
        limit: Int,
        offset: Int,
        nextURL: URL?,
        cacheMode: SpotifyRequestCacheMode
    ) async throws -> SpotifyAPIClient.SpotifyArtistAlbumsPage
    func search(query: String, limit: Int) async throws -> SpotifySearchResults
    func albumTracks(albumID: String, market: String?, limit: Int) async throws -> [SpotifyTrack]
    func albumTracksWithMetrics(albumID: String, market: String?, limit: Int) async throws -> AlbumTrackFetchResult
    /// Single-page album tracks fetch for the artist fallback recovery path. Default-implemented
    /// against `albumTracks` for mocks; the live client overrides with a true `maxPages: 1` call so a
    /// recovery for one album never amplifies into multiple HTTP requests.
    func albumTracksFirstPage(albumID: String, market: String?, limit: Int) async throws -> [SpotifyTrack]
    /// Batched `GET /v1/albums?ids=...` (max 20 IDs). Replaces the per-album loop in the artist
    /// fallback so one HTTP call retrieves up to 20 albums (each with their first 50-track page).
    func albums(ids: [String], market: String?) async throws -> [SpotifyBatchedAlbum]
}

extension SpotifyAPIClient: SpotifyBrowsingAPI {}

extension SpotifyBrowsingAPI {
    func albumTracksWithMetrics(albumID: String, market: String?, limit: Int) async throws -> AlbumTrackFetchResult {
        let tracks = try await albumTracks(albumID: albumID, market: market, limit: limit)
        return AlbumTrackFetchResult(tracks: tracks, pageRequests: 1)
    }

    func albumTracksFirstPage(albumID: String, market: String?, limit: Int) async throws -> [SpotifyTrack] {
        try await albumTracks(albumID: albumID, market: market, limit: limit)
    }

    func playlistTracks(playlistID: String, limit: Int) async throws -> [SpotifyPlaylistTrackItem] {
        try await playlistTracks(playlistID: playlistID, limit: limit, maxPages: 200)
    }
}

protocol SpotifyBrowsingCache {
    func loadPlaylists(now: Date, maxAge: TimeInterval) throws -> [SpotifyPlaylistSummary]?
    /// On-disk playlist list and its age; used to skip a redundant `me/playlists` round-trip when the cache is still fresh.
    func loadPlaylistsBundle(now: Date) throws -> (playlists: [SpotifyPlaylistSummary], age: TimeInterval)?
    func savePlaylists(_ playlists: [SpotifyPlaylistSummary], cachedAt: Date) throws
    func loadTracks(playlistID: String, snapshotID: String, now: Date, maxAge: TimeInterval) throws -> [SpotifyPlaylistTrackItem]?
    func loadTracksIgnoringAge(playlistID: String, snapshotID: String) throws -> [SpotifyPlaylistTrackItem]?
    func saveTracks(_ tracks: [SpotifyPlaylistTrackItem], playlistID: String, snapshotID: String, cachedAt: Date) throws
    func invalidateTracks(playlistID: String) throws
}

extension SpotifyLocalCache: SpotifyBrowsingCache {}

extension SpotifyLocalCache: PinnedItemsCache {}

struct BrowsingDisplayError: Equatable, Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let canRetry: Bool
    let diagnosticDetails: String?

    init(title: String, message: String, canRetry: Bool, diagnosticDetails: String? = nil) {
        self.title = title
        self.message = message
        self.canRetry = canRetry
        self.diagnosticDetails = diagnosticDetails
    }

    static func == (lhs: BrowsingDisplayError, rhs: BrowsingDisplayError) -> Bool {
        lhs.title == rhs.title
            && lhs.message == rhs.message
            && lhs.canRetry == rhs.canRetry
            && lhs.diagnosticDetails == rhs.diagnosticDetails
    }
}

enum BrowsingLoadState<Value: Equatable>: Equatable {
    case loading
    case loaded(Value)
    case empty(String)
    case staleCache(Value, BrowsingDisplayError?)
    case refreshing(Value)
    case error(BrowsingDisplayError)

    var currentValue: Value? {
        switch self {
        case let .loaded(value), let .staleCache(value, _), let .refreshing(value):
            value
        case .loading, .empty, .error:
            nil
        }
    }
}

struct PlaylistRowViewModel: Equatable, Identifiable {
    let id: String
    let title: String
    let owner: String
    let trackCountText: String
    let artworkURL: URL?
    let snapshotID: String

    init(_ playlist: SpotifyPlaylistSummary) {
        self.id = playlist.id
        self.title = playlist.name
        self.owner = playlist.ownerName
        self.trackCountText = playlist.trackCount == 1 ? "1 track" : "\(playlist.trackCount) tracks"
        self.artworkURL = playlist.imageURL
        self.snapshotID = playlist.snapshotID
    }

    /// Virtual library row for Liked Songs (sidebar and detail header). Pass `totalTrackCount: nil` for the sidebar before counts are known (`trackCountText` becomes “Saved tracks”).
    init(likedSongsOwnerDisplay: String, totalTrackCount: Int?, artworkURL: URL?) {
        self.id = SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID
        self.title = "Liked Songs"
        self.owner = likedSongsOwnerDisplay
        if let totalTrackCount {
            self.trackCountText = totalTrackCount == 1 ? "1 track" : "\(totalTrackCount) tracks"
        } else {
            self.trackCountText = "Saved tracks"
        }
        self.artworkURL = artworkURL
        self.snapshotID = SpotiglassSidebarLibrary.likedSongsCacheSnapshotID
    }

    /// Pinned-album header rendered through the existing playlist detail UI.
    /// `albumID` is used as the row id so playback's `activePlaylistID` and the
    /// click-source identification stay consistent with how the rest of the
    /// app keys "currently shown collection".
    init(albumDisplayName: String, artistsDisplay: String, totalTrackCount: Int, artworkURL: URL?, albumID: String) {
        self.id = albumID
        self.title = albumDisplayName
        self.owner = artistsDisplay
        self.trackCountText = totalTrackCount == 1 ? "1 track" : "\(totalTrackCount) tracks"
        self.artworkURL = artworkURL
        self.snapshotID = "album-\(albumID)"
    }
}

struct PlaylistDetailViewModel: Equatable {
    let playlist: PlaylistRowViewModel
    let tracks: [TrackRowViewModel]
}

enum BrowsingDetailContent: Equatable {
    case playlist(PlaylistDetailViewModel)
    case artist(ArtistDetailViewModel)
}

struct ArtistAlbumRowViewModel: Equatable, Identifiable {
    let id: String
    let title: String
    let artworkURL: URL?
    let yearText: String?
    let trackCountText: String
    let uri: String

    init(_ album: SpotifyArtistAlbum) {
        id = album.id
        title = album.name
        artworkURL = album.imageURL
        yearText = album.releaseYear
        trackCountText = album.totalTracks == 1 ? "1 track" : "\(album.totalTracks) tracks"
        uri = album.uri
    }
}

struct ArtistDetailViewModel: Equatable {
    let artist: SpotifyArtistDetail
    let tracks: [TrackRowViewModel]
    let albums: [ArtistAlbumRowViewModel]
    let singles: [ArtistAlbumRowViewModel]
    let compilations: [ArtistAlbumRowViewModel]
    let appearsOn: [ArtistAlbumRowViewModel]
    let canLoadMoreAlbums: Bool
    let isLoadingMoreAlbums: Bool

    init(
        artist: SpotifyArtistDetail,
        tracks: [SpotifyTrack],
        albums: [SpotifyArtistAlbum],
        canLoadMoreAlbums: Bool = false,
        isLoadingMoreAlbums: Bool = false
    ) {
        self.artist = artist
        self.tracks = TrackRowViewModel.numberedTopTracks(tracks)
        let grouped = Dictionary(grouping: albums, by: \.group)
        let sort: (SpotifyArtistAlbum, SpotifyArtistAlbum) -> Bool = { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        self.albums = (grouped[.album] ?? []).sorted(by: sort).map(ArtistAlbumRowViewModel.init)
        self.singles = (grouped[.single] ?? []).sorted(by: sort).map(ArtistAlbumRowViewModel.init)
        self.compilations = (grouped[.compilation] ?? []).sorted(by: sort).map(ArtistAlbumRowViewModel.init)
        self.appearsOn = (grouped[.appearsOn] ?? []).sorted(by: sort).map(ArtistAlbumRowViewModel.init)
        self.canLoadMoreAlbums = canLoadMoreAlbums
        self.isLoadingMoreAlbums = isLoadingMoreAlbums
    }
}

struct TrackRowViewModel: Equatable, Identifiable {
    let id: String
    /// 1-based row index in playlist / artist track lists (for ``TrackListRow``).
    let listPosition: Int
    let title: String
    let subtitle: String
    let artworkURL: URL?
    let durationText: String
    let badgeText: String?
    let isUnavailable: Bool
    let playableURI: String?
    let artistRefs: [SpotifyArtistRef]

    /// Builds playlist rows with stable numbering without allocating `enumerated()` in SwiftUI bodies.
    static func numberedPlaylistRows(_ items: [SpotifyPlaylistTrackItem]) -> [TrackRowViewModel] {
        items.enumerated().map { index, item in
            TrackRowViewModel(item, listPosition: index + 1)
        }
    }

    /// Builds artist (or album) top-track rows with stable numbering.
    static func numberedTopTracks(_ tracks: [SpotifyTrack]) -> [TrackRowViewModel] {
        tracks.enumerated().map { index, track in
            TrackRowViewModel(topTrack: track, listPosition: index + 1)
        }
    }

    init(_ item: SpotifyPlaylistTrackItem, listPosition: Int) {
        self.listPosition = listPosition
        self.id = item.id

        switch item.content {
        case let .track(track):
            self.title = track.name
            self.subtitle = track.artists.joined(separator: ", ")
            self.artworkURL = track.albumArtworkURL
            self.durationText = Self.durationText(milliseconds: track.durationMilliseconds)
            self.badgeText = track.isPlayable == false ? "Unavailable" : (track.isExplicit ? "Explicit" : nil)
            self.isUnavailable = track.isPlayable == false
            self.playableURI = track.isPlayable == false ? nil : track.uri
            self.artistRefs = track.artistRefs
        case let .episode(episode):
            self.title = episode.name
            self.subtitle = episode.showName ?? "Podcast episode"
            self.artworkURL = episode.artworkURL
            self.durationText = Self.durationText(milliseconds: episode.durationMilliseconds)
            self.badgeText = episode.isPlayable == false ? "Unavailable episode" : "Episode"
            self.isUnavailable = episode.isPlayable == false
            self.playableURI = episode.isPlayable == false ? nil : episode.uri
            self.artistRefs = []
        case let .localTrack(track):
            self.title = track.name
            self.subtitle = track.artists.isEmpty ? "Local track" : track.artists.joined(separator: ", ")
            self.artworkURL = nil
            self.durationText = Self.durationText(milliseconds: track.durationMilliseconds)
            self.badgeText = "Local"
            self.isUnavailable = false
            self.playableURI = nil
            self.artistRefs = []
        case let .unavailable(reason):
            self.title = "Unavailable item"
            self.subtitle = reason
            self.artworkURL = nil
            self.durationText = "--:--"
            self.badgeText = "Unavailable"
            self.isUnavailable = true
            self.playableURI = nil
            self.artistRefs = []
        }
    }

    init(topTrack track: SpotifyTrack, listPosition: Int) {
        self.listPosition = listPosition
        self.id = track.id
        self.title = track.name
        self.subtitle = track.artists.joined(separator: ", ")
        self.artworkURL = track.albumArtworkURL
        self.durationText = Self.durationText(milliseconds: track.durationMilliseconds)
        self.badgeText = track.isPlayable == false ? "Unavailable" : (track.isExplicit ? "Explicit" : nil)
        self.isUnavailable = track.isPlayable == false
        self.playableURI = track.isPlayable == false ? nil : track.uri
        self.artistRefs = track.artistRefs
    }

    private static func durationText(milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds / 1_000)
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }

    /// Milliseconds parsed from ``durationText`` (`m:ss`); `0` when unparsable.
    var durationMillisecondsForPinning: Int {
        let parts = durationText.split(separator: ":")
        guard parts.count == 2,
              let m = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let s = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { return 0 }
        return max(0, (m * 60 + s) * 1_000)
    }

    /// Domain track for palette pinning and draggable pins; `nil` for episodes, locals, and unavailable rows.
    func spotifyTrackForPinning(originPlaylistID: String?) -> SpotifyTrack? {
        guard let playableURI, playableURI.hasPrefix("spotify:track:") else { return nil }
        let names: [String] = artistRefs.map(\.name).isEmpty
            ? subtitle.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            : artistRefs.map(\.name)
        return SpotifyTrack(
            id: id,
            name: title,
            artists: names,
            artistRefs: artistRefs,
            albumArtworkURL: artworkURL,
            durationMilliseconds: durationMillisecondsForPinning,
            isExplicit: badgeText == "Explicit",
            isPlayable: !isUnavailable,
            linkedFromID: nil,
            uri: playableURI
        )
    }

    func pinnedTrackItem(originPlaylistID: String?) -> PinnedItem? {
        guard let track = spotifyTrackForPinning(originPlaylistID: originPlaylistID) else { return nil }
        return .track(track, originPlaylistID: originPlaylistID)
    }
}

extension ArtistAlbumRowViewModel {
    private var parsedTotalTrackCount: Int {
        let digits = trackCountText.prefix { $0.isNumber }
        return Int(digits) ?? 1
    }

    func spotifyArtistAlbum(group: SpotifyArtistAlbumGroup) -> SpotifyArtistAlbum {
        SpotifyArtistAlbum(
            id: id,
            name: title,
            imageURL: artworkURL,
            releaseYear: yearText,
            totalTracks: parsedTotalTrackCount,
            group: group,
            uri: uri
        )
    }

    func pinnedAlbum(group: SpotifyArtistAlbumGroup) -> PinnedItem {
        .album(spotifyArtistAlbum(group: group))
    }
}

@MainActor
final class PlaylistBrowserViewModel: ObservableObject {
    struct ArtistFetchMetrics: Equatable {
        var requestStarts = 0
        var coalescedRequests = 0
        var staleResponsesServed = 0
        var forcedRefreshRuns = 0
        var albumFallbackAlbumAttempts = 0
        var albumFallbackUniqueAlbums = 0
        /// Number of album-track pages requested via `albumTracksFirstPage` recoveries (formerly counted
        /// per-album page requests in the legacy N+1 loop; now bounded to at most one per artist load).
        var albumFallbackPagesFetched = 0
        /// Incremented when fallback bails out: budget exhausted, batched call failed, or 429-skip applied.
        /// At most one increment per artist load (no longer multi-incremented per album iteration).
        var albumFallbackBudgetStops = 0
        /// Number of batched `GET /v1/albums?ids=...` calls made for this artist load (0 or 1).
        var albumFallbackBatchedCalls = 0
        /// Number of single-album `albumTracks` recovery calls (0 or 1, gated by strategy).
        var albumFallbackRecoveryCalls = 0
    }

    @Published private(set) var playlistState: BrowsingLoadState<[PlaylistRowViewModel]> = .loading
    @Published private(set) var detailState: BrowsingLoadState<BrowsingDetailContent> = .empty("Select an item in the sidebar or open an artist from search.")
    @Published var sidebarSelection: SidebarSelection?
    @Published private(set) var canNavigateBack = false
    /// Logical drill-in path for the principal toolbar; empty at Home.
    @Published private(set) var breadcrumbPath: [BrowserBreadcrumb] = []

    /// Immersive lyrics cover the window; unified refresh targets the underlying browser surface.
    var refreshRoutingLyricsPresented = false
    /// Playback queue panel visibility; synced from the browser view.
    var refreshRoutingQueuePanelVisible = false
    /// Whether the queue column owns refresh focus (⌘R / toolbar); synced from the browser view.
    var refreshRoutingQueuePanelFocused = false
    /// True only during a user-initiated queue refresh from the unified control (not background polling).
    @Published private(set) var isUnifiedQueueRefreshActive = false

    /// When the sidebar shows a Spotify playlist row; used by search / command palette.
    var selectedPlaylistID: String? {
        if case let .playlist(id) = sidebarSelection { return id }
        return nil
    }

    /// True when the command palette can scope “Here” to the current main view: a loaded **artist** (sidebar is nil), or a **playlist / Liked Songs** row with loaded playlist detail.
    var isCommandPaletteContextSearchEligible: Bool {
        guard let content = detailState.currentValue else { return false }
        switch content {
        case .artist:
            return true
        case .playlist:
            guard let selection = sidebarSelection else { return false }
            switch selection {
            case .playlist, .likedSongs: return true
            case .home, .pinnedItem: return false
            }
        }
    }

    /// Top/loaded tracks for the current **playlist** or **artist** detail, for palette “Here” / merged-in-page search.
    var loadedContextTracksForPalette: [TrackRowViewModel]? {
        guard let content = detailState.currentValue else { return nil }
        switch content {
        case let .playlist(vm): return vm.tracks
        case let .artist(vm): return vm.tracks
        }
    }

    private let api: SpotifyBrowsingAPI
    private let cache: SpotifyBrowsingCache
    private let now: () -> Date
    private let maxCacheAge: TimeInterval
    /// When the saved playlist list is younger than this, `load()` does not call `refreshPlaylists()` (tracks for the selection still revalidate in the background when a track cache hit exists).
    private let playlistListAutoRefreshMinInterval: TimeInterval
    /// Skip background `/items` revalidation when disk cache is fresh and this playlist was revalidated recently with the same snapshot.
    private let tracksRevalidateMinInterval: TimeInterval
    /// Cool-down for user-initiated Home refreshes to avoid bursty list reloads.
    private let manualPlaylistRefreshCooldown: TimeInterval
    /// Short cool-down for automatic liked-songs revalidation when cache is already fresh.
    private let likedSongsAutoRefreshMinInterval: TimeInterval
    /// TTL for artist detail soft cache to prevent bursty repeated full refetches.
    private let artistDetailCacheTTL: TimeInterval
    /// Number of artist album pages to load initially before exposing "Load more".
    private let initialArtistAlbumPageCount: Int
    private var playlistsByID: [String: SpotifyPlaylistSummary] = [:]
    private var hasLoaded = false
    private var detailSession = 0
    private var detailLoadTask: Task<Void, Never>?
    private var detailLoadGeneration = 0
    private var adjacentPlaylistSelectionTask: Task<Void, Never>?
    private var pendingAdjacentPlaylistOffset: Int = 0
    private var lastTracksRevalidationByID: [String: (snapshotID: String, at: Date)] = [:]
    private var inFlightPlaylistListRefreshTask: Task<[SpotifyPlaylistSummary], Error>?
    private var playlistListRefreshGeneration = 0
    private var lastManualPlaylistRefreshAt: Date?
    /// Collapses concurrent liked-songs refresh triggers into one network run.
    private var likedSongsRevalidationTask: Task<SpotifySavedTracksResult, Error>?
    private var lastLikedSongsRevalidationAt: Date?
    private var artistDetailLoadTasks: [String: Task<ArtistDetailSnapshot, Error>] = [:]
    private var cachedArtistSnapshots: [String: CachedArtistSnapshot] = [:]
    private var currentArtistAlbumsPaging: ArtistAlbumsPagingState?
    private var lastArtistSelectionAt: [String: Date] = [:]
    private let artistSelectionDebounceWindow: TimeInterval = 0.4
    private(set) var artistFetchMetrics = ArtistFetchMetrics()
    /// Clears sidebar selection when opening an artist; SwiftUI then calls `selectSidebar(nil)`, which must not reset the detail pane or bump `detailSession`.
    private var ignoreNextNilSidebarSelectionForDetail = false
    private var backNavigationStack: [BrowserNavigationTarget] = []
    private var currentNavigationTarget: BrowserNavigationTarget?
    private var isPerformingBackNavigation = false
    private let maxBackNavigationDepth = 40

    private struct ArtistDetailSnapshot {
        let artistDetail: SpotifyArtistDetail
        let albums: [SpotifyArtistAlbum]
        let tracks: [SpotifyTrack]
        let usedStaleCache: Bool
        let paging: ArtistAlbumsPagingState?
    }

    private struct CachedArtistSnapshot {
        let snapshot: ArtistDetailSnapshot
        let fetchedAt: Date
    }

    private struct ArtistAlbumsPagingState {
        let artistID: String
        let includeGroups: String
        let limit: Int
        var nextURL: URL?
        var nextOffset: Int
        var albums: [SpotifyArtistAlbum]
        let tracks: [SpotifyTrack]
        var isLoading = false
        var seenNextURLs: Set<String> = []
    }
    /// Endpoint breaker for `/v1/artists/{id}/top-tracks` keyed by artist and market to avoid repeatedly probing known-forbidden or rate-limited paths.
    private var artistTopTracksProbeState: [ArtistTopTracksProbeKey: ArtistTopTracksProbeState] = [:]
    /// Endpoint breaker for batched `/v1/albums?ids=...` fallback calls keyed by artist+market.
    private var artistBatchedAlbumsCooldownUntil: [ArtistTopTracksProbeKey: Date] = [:]
    /// Session-level guard to avoid rapid refetching the same failed album-batch signature.
    private var failedArtistAlbumBatchCooldownUntil: [String: Date] = [:]
    /// Session-level guard to avoid repeated single-album recovery calls for the same album.
    private var attemptedArtistAlbumRecoveryIDs: Set<String> = []

    var visiblePlaylists: [PlaylistRowViewModel] {
        playlistState.currentValue ?? []
    }

    init(
        api: SpotifyBrowsingAPI,
        cache: SpotifyBrowsingCache,
        now: @escaping () -> Date = Date.init,
        maxCacheAge: TimeInterval = 1800,
        playlistListAutoRefreshMinInterval: TimeInterval = 1800,
        tracksRevalidateMinInterval: TimeInterval = 30,
        likedSongsAutoRefreshMinInterval: TimeInterval = 120,
        manualPlaylistRefreshCooldown: TimeInterval = 2,
        artistDetailCacheTTL: TimeInterval = 90,
        initialArtistAlbumPageCount: Int = 2
    ) {
        self.api = api
        self.cache = cache
        self.now = now
        self.maxCacheAge = maxCacheAge
        self.playlistListAutoRefreshMinInterval = playlistListAutoRefreshMinInterval
        self.tracksRevalidateMinInterval = tracksRevalidateMinInterval
        self.likedSongsAutoRefreshMinInterval = likedSongsAutoRefreshMinInterval
        self.manualPlaylistRefreshCooldown = manualPlaylistRefreshCooldown
        self.artistDetailCacheTTL = artistDetailCacheTTL
        self.initialArtistAlbumPageCount = max(1, initialArtistAlbumPageCount)
    }

    static func live(tokenProvider: SpotifyAccessTokenProviding) -> PlaylistBrowserViewModel {
        let api = SpotifyAPIClient(tokenProvider: tokenProvider, getResponseCache: .shared)
        let cache: SpotifyBrowsingCache = (try? SpotifyLocalCache()) ?? DisabledSpotifyBrowsingCache()
        return PlaylistBrowserViewModel(api: api, cache: cache)
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await load()
    }

    func load() async {
        if let bundle = try? cache.loadPlaylistsBundle(now: now()), !bundle.playlists.isEmpty {
            apply(playlists: bundle.playlists, state: .loaded(bundle.playlists.map(PlaylistRowViewModel.init)), preserveSelection: true)
            if bundle.age >= playlistListAutoRefreshMinInterval {
                await refreshPlaylists(trigger: .automatic)
            } else {
                if let sidebarSelection {
                    detailSession += 1
                    let session = detailSession
                    await scheduleDetailLoad(for: sidebarSelection, refreshCachedData: true, session: session)
                }
            }
            return
        }

        playlistState = .loading
        await refreshPlaylists(trigger: .automatic)
    }

    func refreshPlaylists(trigger: PlaylistRefreshTrigger = .automatic) async {
        let existingRows = playlistState.currentValue
        if let existingRows, !existingRows.isEmpty {
            playlistState = .refreshing(existingRows)
        }

        do {
            let playlists = try await fetchPlaylistsForRefresh(trigger: trigger)
            try? cache.savePlaylists(playlists, cachedAt: now())
            if playlists.isEmpty {
                playlistsByID = [:]
                sidebarSelection = nil
                playlistState = .empty("Your Spotify library has no playlists yet.")
                detailState = .empty("Create or follow a playlist in Spotify, then refresh.")
                return
            }
            let selectionBefore = sidebarSelection
            let playlistIDBefore: String? = {
                if case let .playlist(id) = selectionBefore { return id }
                return nil
            }()
            let snapshotBeforeRefresh = playlistIDBefore.flatMap { playlistsByID[$0]?.snapshotID }

            apply(playlists: playlists, state: .loaded(playlists.map(PlaylistRowViewModel.init)), preserveSelection: true)

            guard let selectionAfter = sidebarSelection else { return }

            let shouldScheduleDetailReload: Bool = {
                switch selectionAfter {
                case .likedSongs:
                    return false
                case .home, .pinnedItem:
                    return selectionBefore != selectionAfter
                case let .playlist(idAfter):
                    if case let .playlist(idBefore) = selectionBefore, idBefore == idAfter {
                        let newSnap = playlistsByID[idAfter]?.snapshotID
                        return newSnap != snapshotBeforeRefresh
                    }
                    return true
                }
            }()

            if shouldScheduleDetailReload {
                detailSession += 1
                let session = detailSession
                await scheduleDetailLoad(for: selectionAfter, refreshCachedData: true, session: session)
            }
        } catch {
            let displayError = Self.displayError(for: error)
            if let existingRows, !existingRows.isEmpty {
                playlistState = .staleCache(existingRows, displayError)
            } else {
                playlistState = .error(displayError)
            }
        }
    }

    func selectSidebar(_ selection: SidebarSelection?, origin: BrowserNavigationOrigin = .reset) async {
        adjacentPlaylistSelectionTask?.cancel()
        adjacentPlaylistSelectionTask = nil
        pendingAdjacentPlaylistOffset = 0
        guard let selection else {
            sidebarSelection = nil
            if ignoreNextNilSidebarSelectionForDetail {
                ignoreNextNilSidebarSelectionForDetail = false
                return
            }
            if origin != .backStackReplay {
                breadcrumbPath = []
            }
            currentNavigationTarget = nil
            syncCanNavigateBack()
            detailSession += 1
            detailState = .empty("Select an item in the sidebar or open an artist from search.")
            return
        }

        // Pinned-item taps are dispatched in the view layer (it owns the
        // `PinnedItemsStore` and the playback view-model needed for tracks).
        // Just record the selection so list highlight stays in sync.
        if case .pinnedItem = selection {
            sidebarSelection = selection
            return
        }

        registerNavigationTransition(to: .sidebar(selection))
        applyBreadcrumbForSidebar(selection, origin: origin)
        ignoreNextNilSidebarSelectionForDetail = false
        detailSession += 1
        let session = detailSession
        sidebarSelection = selection
        await scheduleDetailLoad(for: selection, refreshCachedData: true, session: session)
    }

    /// Loads an album by ID and renders it through the existing playlist
    /// detail content. Album metadata (title / artist line / artwork) is
    /// supplied by the caller (typically a pinned item snapshot) so the
    /// header is populated even when offline.
    func selectAlbum(
        id: String,
        displayTitle: String,
        displaySubtitle: String,
        artworkURL: URL?,
        origin: BrowserNavigationOrigin = .reset
    ) async {
        registerNavigationTransition(to: .album(id: id, title: displayTitle, subtitle: displaySubtitle, artworkURL: artworkURL))
        applyBreadcrumbForAlbum(
            id: id,
            title: displayTitle,
            subtitle: displaySubtitle,
            artworkURL: artworkURL,
            origin: origin
        )
        ignoreNextNilSidebarSelectionForDetail = false
        detailSession += 1
        let session = detailSession
        detailLoadTask?.cancel()
        detailLoadGeneration += 1
        let generation = detailLoadGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.loadAlbumDetail(
                id: id,
                displayTitle: displayTitle,
                displaySubtitle: displaySubtitle,
                artworkURL: artworkURL,
                session: session
            )
        }
        detailLoadTask = task
        await task.value
        if generation == detailLoadGeneration {
            detailLoadTask = nil
        }
    }

    private func loadAlbumDetail(
        id: String,
        displayTitle: String,
        displaySubtitle: String,
        artworkURL: URL?,
        session: Int
    ) async {
        guard !Task.isCancelled else { return }
        detailState = .loading
        do {
            let profile = try? await api.currentUserProfile()
            let market = profile?.country
            let tracks = try await api.albumTracks(albumID: id, market: market, limit: 50).map { track in
                guard track.albumArtworkURL == nil, let artworkURL else {
                    return track
                }
                return SpotifyTrack(
                    id: track.id,
                    name: track.name,
                    artists: track.artists,
                    artistRefs: track.artistRefs,
                    albumArtworkURL: artworkURL,
                    albumName: track.albumName,
                    albumID: track.albumID,
                    durationMilliseconds: track.durationMilliseconds,
                    isExplicit: track.isExplicit,
                    isPlayable: track.isPlayable,
                    linkedFromID: track.linkedFromID,
                    uri: track.uri
                )
            }
            guard session == detailSession else { return }
            let header = PlaylistRowViewModel(
                albumDisplayName: displayTitle,
                artistsDisplay: displaySubtitle,
                totalTrackCount: tracks.count,
                artworkURL: artworkURL,
                albumID: id
            )
            let trackRows = TrackRowViewModel.numberedTopTracks(tracks)
            if trackRows.isEmpty {
                detailState = .empty("This album has no tracks available.")
            } else {
                detailState = .loaded(.playlist(PlaylistDetailViewModel(playlist: header, tracks: trackRows)))
            }
        } catch is CancellationError {
            return
        } catch {
            guard session == detailSession else { return }
            detailState = .error(Self.displayError(for: error))
        }
    }

    func selectPlaylist(id: String?, origin: BrowserNavigationOrigin = .reset) async {
        if let id {
            await selectSidebar(.playlist(id), origin: origin)
        } else {
            await selectSidebar(nil, origin: origin)
        }
    }

    func selectArtist(
        id: String,
        forceRefresh: Bool = false,
        origin: BrowserNavigationOrigin = .reset,
        displayName: String? = nil
    ) async {
        registerNavigationTransition(to: .artist(id))
        applyBreadcrumbForArtist(
            id: id,
            displayName: displayName,
            origin: origin
        )
        let nowDate = now()
        detailLoadTask?.cancel()

        if !forceRefresh,
           let cached = cachedArtistSnapshots[id],
           nowDate.timeIntervalSince(cached.fetchedAt) < artistDetailCacheTTL {
            currentArtistAlbumsPaging = cached.snapshot.paging
            let cachedVM = ArtistDetailViewModel(
                artist: cached.snapshot.artistDetail,
                tracks: cached.snapshot.tracks,
                albums: cached.snapshot.albums,
                canLoadMoreAlbums: cached.snapshot.paging?.nextURL != nil,
                isLoadingMoreAlbums: cached.snapshot.paging?.isLoading == true
            )
            ignoreNextNilSidebarSelectionForDetail = true
            sidebarSelection = nil
            detailSession += 1
            detailState = .loaded(.artist(cachedVM))
            refineLastBreadcrumbArtistLabelIfNeeded(artistID: id, resolvedName: cached.snapshot.artistDetail.name)
            return
        }
        if let lastSelection = lastArtistSelectionAt[id],
           nowDate.timeIntervalSince(lastSelection) < artistSelectionDebounceWindow,
           artistDetailLoadTasks[id] != nil {
            artistFetchMetrics.coalescedRequests += 1
            return
        }
        lastArtistSelectionAt[id] = nowDate

        ignoreNextNilSidebarSelectionForDetail = true
        sidebarSelection = nil
        detailSession += 1
        let session = detailSession
        detailState = .loading
        do {
            let snapshot = try await loadArtistDetailSnapshot(id: id, preferCached: false)
            guard session == detailSession else { return }
            currentArtistAlbumsPaging = snapshot.paging
            if snapshot.usedStaleCache {
                artistFetchMetrics.staleResponsesServed += 1
                let staleVM = ArtistDetailViewModel(
                    artist: snapshot.artistDetail,
                    tracks: snapshot.tracks,
                    albums: snapshot.albums,
                    canLoadMoreAlbums: snapshot.paging?.nextURL != nil
                )
                detailState = .refreshing(.artist(staleVM))
                artistFetchMetrics.forcedRefreshRuns += 1
                let refreshed = try await loadArtistDetailSnapshot(id: id, preferCached: false)
                guard session == detailSession else { return }
                currentArtistAlbumsPaging = refreshed.paging
                let refreshedVM = ArtistDetailViewModel(
                    artist: refreshed.artistDetail,
                    tracks: refreshed.tracks,
                    albums: refreshed.albums,
                    canLoadMoreAlbums: refreshed.paging?.nextURL != nil
                )
                cachedArtistSnapshots[id] = CachedArtistSnapshot(snapshot: refreshed, fetchedAt: now())
                detailState = .loaded(.artist(refreshedVM))
                refineLastBreadcrumbArtistLabelIfNeeded(artistID: id, resolvedName: refreshed.artistDetail.name)
                return
            }
            guard session == detailSession else { return }
            let vm = ArtistDetailViewModel(
                artist: snapshot.artistDetail,
                tracks: snapshot.tracks,
                albums: snapshot.albums,
                canLoadMoreAlbums: snapshot.paging?.nextURL != nil
            )
            cachedArtistSnapshots[id] = CachedArtistSnapshot(snapshot: snapshot, fetchedAt: now())
            detailState = .loaded(.artist(vm))
            refineLastBreadcrumbArtistLabelIfNeeded(artistID: id, resolvedName: snapshot.artistDetail.name)
        } catch {
            guard session == detailSession else { return }
            detailState = .error(Self.displayError(for: error))
        }
    }

    func loadMoreArtistAlbums() async {
        guard case let .loaded(.artist(detail)) = detailState,
              var paging = currentArtistAlbumsPaging,
              !paging.isLoading,
              let nextURL = paging.nextURL else {
            return
        }

        paging.isLoading = true
        currentArtistAlbumsPaging = paging
        detailState = .loaded(.artist(
            ArtistDetailViewModel(
                artist: detail.artist,
                tracks: paging.tracks,
                albums: paging.albums,
                canLoadMoreAlbums: true,
                isLoadingMoreAlbums: true
            )
        ))

        do {
            if paging.seenNextURLs.contains(nextURL.absoluteString) {
                paging.nextURL = nil
            } else {
                paging.seenNextURLs.insert(nextURL.absoluteString)
                let page = try await api.artistAlbumsPage(
                    id: paging.artistID,
                    includeGroups: paging.includeGroups,
                    limit: paging.limit,
                    offset: paging.nextOffset,
                    nextURL: nextURL,
                    cacheMode: .bypassCache
                )
                paging.albums = Self.dedupeAlbums(paging.albums + page.items)
                paging.nextURL = page.next
                paging.nextOffset += paging.limit
            }
            paging.isLoading = false
            currentArtistAlbumsPaging = paging
            let refreshed = ArtistDetailViewModel(
                artist: detail.artist,
                tracks: paging.tracks,
                albums: paging.albums,
                canLoadMoreAlbums: paging.nextURL != nil,
                isLoadingMoreAlbums: false
            )
            cachedArtistSnapshots[detail.artist.id] = CachedArtistSnapshot(
                snapshot: ArtistDetailSnapshot(
                    artistDetail: detail.artist,
                    albums: paging.albums,
                    tracks: paging.tracks,
                    usedStaleCache: false,
                    paging: paging
                ),
                fetchedAt: now()
            )
            detailState = .loaded(.artist(refreshed))
        } catch {
            paging.isLoading = false
            currentArtistAlbumsPaging = paging
            detailState = .staleCache(.artist(detail), Self.displayError(for: error))
        }
    }

    private func loadArtistDetailSnapshot(id: String, preferCached: Bool) async throws -> ArtistDetailSnapshot {
        if let inFlight = artistDetailLoadTasks[id] {
            artistFetchMetrics.coalescedRequests += 1
            return try await inFlight.value
        }
        artistFetchMetrics.requestStarts += 1
        let task = Task { [api] in
            let profile = try await api.currentUserProfile()
            let market = profile.country
            if preferCached {
                async let cachedDetail = api.artistCached(id: id, cacheMode: .allowStale)
                async let cachedAlbums = api.artistAlbumsCached(
                    id: id,
                    includeGroups: "album,single,compilation",
                    limit: 10,
                    cacheMode: .allowStale
                )
                let (detailHit, albumsHit) = try await (cachedDetail, cachedAlbums)
                let tracks = await self.resolveArtistTracks(
                    artistId: id,
                    artist: detailHit.value,
                    albums: albumsHit.value,
                    market: market
                )
                return ArtistDetailSnapshot(
                    artistDetail: detailHit.value,
                    albums: albumsHit.value,
                    tracks: tracks,
                    usedStaleCache: detailHit.isStale || albumsHit.isStale,
                    paging: nil
                )
            }
            let artistDetail = try await api.artist(id: id, cacheMode: .bypassCache)
            let includeGroups = "album,single,compilation"
            let limit = 10
            var nextURL: URL?
            var nextOffset = 0
            var pagesFetched = 0
            var seenNextURLs: Set<String> = []
            var albumList: [SpotifyArtistAlbum] = []
            repeat {
                if let url = nextURL {
                    let key = url.absoluteString
                    if seenNextURLs.contains(key) {
                        break
                    }
                    seenNextURLs.insert(key)
                }
                let page = try await api.artistAlbumsPage(
                    id: id,
                    includeGroups: includeGroups,
                    limit: limit,
                    offset: nextOffset,
                    nextURL: nextURL,
                    cacheMode: .bypassCache
                )
                albumList = Self.dedupeAlbums(albumList + page.items)
                pagesFetched += 1
                nextOffset += limit
                nextURL = page.next
            } while nextURL != nil && pagesFetched < self.initialArtistAlbumPageCount
            let resolved = await self.resolveArtistTracks(artistId: id, artist: artistDetail, albums: albumList, market: market)
            let paging = ArtistAlbumsPagingState(
                artistID: id,
                includeGroups: includeGroups,
                limit: limit,
                nextURL: nextURL,
                nextOffset: nextOffset,
                albums: albumList,
                tracks: resolved,
                isLoading: false,
                seenNextURLs: seenNextURLs
            )
            return ArtistDetailSnapshot(
                artistDetail: artistDetail,
                albums: albumList,
                tracks: resolved,
                usedStaleCache: false,
                paging: paging
            )
        }
        artistDetailLoadTasks[id] = task
        defer { artistDetailLoadTasks[id] = nil }
        return try await task.value
    }

    /// Prefer Spotify top-tracks; when forbidden/unavailable (common for Web API dev-mode apps), fall back to
    /// search then album-derived tracks. The album fallback issues **one** batched `GET /v1/albums?ids=...`
    /// call covering up to `strategy.maxAlbumRequests` IDs, plus at most one single-album recovery if the
    /// batched response was missing tracks for an album we still need. Long-retry 429s short-circuit the
    /// album fallback entirely so we don't cascade rate-limit pain into more outbound calls.
    private func resolveArtistTracks(
        artistId: String,
        artist: SpotifyArtistDetail,
        albums: [SpotifyArtistAlbum],
        market: String?
    ) async -> [SpotifyTrack] {
        let probeKey = ArtistTopTracksProbeKey(artistID: artistId, market: market)
        var fallbackBudgetMode: AlbumFallbackBudgetMode = .healthy
        if shouldProbeTopTracks(for: probeKey, now: now()) {
            do {
                let top = try await api.artistTopTracks(id: artistId, market: market)
                registerTopTracksProbeSuccess(for: probeKey)
                if !top.isEmpty {
                    return top
                }
            } catch {
                fallbackBudgetMode = registerTopTracksProbeFailure(error, for: probeKey, now: now())
                // Non-fatal: continue with fallbacks (403 Forbidden on `/top-tracks` is expected for dev-mode apps).
            }
        }

        do {
            let sanitizedName = artist.name.replacingOccurrences(of: "\"", with: "")
            let query = "artist:\"\(sanitizedName)\""
            let results = try await api.search(query: query, limit: 10)
            let matching = results.tracks.filter { $0.artistRefs.contains { $0.id == artistId } }
            if !matching.isEmpty {
                return Array(matching.prefix(10))
            }
        } catch {
            // Non-fatal: try album-derived list.
        }

        if fallbackBudgetMode == .skipped {
            // 429 with a long retry-after: skip the album fallback entirely instead of stacking another
            // outbound call onto a back-off window.
            artistFetchMetrics.albumFallbackBudgetStops += 1
            return []
        }

        let strategy = ArtistAlbumFallbackStrategy(rateLimited: fallbackBudgetMode == .rateLimitedReduced)
        let selectedAlbums = Self.albumsForTrackFallback(from: albums, maxCount: strategy.maxAlbumRequests)
        artistFetchMetrics.albumFallbackAlbumAttempts = selectedAlbums.count
        artistFetchMetrics.albumFallbackUniqueAlbums = Set(selectedAlbums.map { $0.id }).count
        guard !selectedAlbums.isEmpty else {
            return []
        }

        var albumImagesByID: [String: URL] = [:]
        for album in selectedAlbums {
            if let url = album.imageURL {
                albumImagesByID[album.id] = url
            }
        }
        let ids = selectedAlbums.map(\.id)
        var collected: [SpotifyTrack] = []
        if shouldSkipBatchedAlbumsFallback(for: probeKey, now: now()) {
            artistFetchMetrics.albumFallbackBudgetStops += 1
            return collected
        }
        let batchSignature = Self.artistAlbumBatchSignature(artistID: artistId, market: market, ids: ids)
        if shouldSkipFailedArtistAlbumBatch(signature: batchSignature, now: now()) {
            artistFetchMetrics.albumFallbackBudgetStops += 1
            return collected
        }

        let batchedAlbums: [String: SpotifyBatchedAlbum]
        do {
            let response = try await api.albums(ids: ids, market: market)
            artistFetchMetrics.albumFallbackBatchedCalls += 1
            batchedAlbums = Dictionary(uniqueKeysWithValues: response.map { ($0.id, $0) })
        } catch {
            if case let SpotifyAPIError.rateLimited(retryAfter) = error {
                let until = registerBatchedAlbumsRateLimit(for: probeKey, retryAfter: retryAfter, now: now())
                failedArtistAlbumBatchCooldownUntil[batchSignature] = until
            }
            artistFetchMetrics.albumFallbackBudgetStops += 1
            return []
        }

        var seenNames: Set<String> = []
        for album in selectedAlbums {
            guard let entry = batchedAlbums[album.id] else { continue }
            Self.appendUniqueFallbackTracks(
                from: entry.tracks,
                albumArtworkFallback: albumImagesByID[album.id],
                into: &collected,
                seen: &seenNames,
                limit: 10
            )
            if collected.count >= 10 {
                return collected
            }
        }

        if collected.count < 10, strategy.maxRecoveryCalls > 0 {
            let recoveryCandidate = selectedAlbums.first { album in
                guard !attemptedArtistAlbumRecoveryIDs.contains(album.id) else { return false }
                guard let entry = batchedAlbums[album.id] else { return false }
                return entry.tracksAvailable == false
            }
            if let recoveryCandidate {
                do {
                    attemptedArtistAlbumRecoveryIDs.insert(recoveryCandidate.id)
                    let recovered = try await api.albumTracksFirstPage(
                        albumID: recoveryCandidate.id,
                        market: market,
                        limit: 10
                    )
                    artistFetchMetrics.albumFallbackRecoveryCalls += 1
                    artistFetchMetrics.albumFallbackPagesFetched = 1
                    Self.appendUniqueFallbackTracks(
                        from: recovered,
                        albumArtworkFallback: albumImagesByID[recoveryCandidate.id],
                        into: &collected,
                        seen: &seenNames,
                        limit: 10
                    )
                } catch {
                    artistFetchMetrics.albumFallbackBudgetStops += 1
                }
            }
        }

        return collected
    }

    /// Appends up to `limit - collected.count` deduped tracks from `source` into `collected`,
    /// patching `albumArtworkURL` from the album row when the embedded track was missing artwork.
    private static func appendUniqueFallbackTracks(
        from source: [SpotifyTrack],
        albumArtworkFallback: URL?,
        into collected: inout [SpotifyTrack],
        seen: inout Set<String>,
        limit: Int
    ) {
        for track in source {
            if collected.count >= limit { return }
            let key = track.name.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let withArt: SpotifyTrack
            if track.albumArtworkURL == nil, let url = albumArtworkFallback {
                withArt = SpotifyTrack(
                    id: track.id,
                    name: track.name,
                    artists: track.artists,
                    artistRefs: track.artistRefs,
                    albumArtworkURL: url,
                    albumName: track.albumName,
                    albumID: track.albumID,
                    durationMilliseconds: track.durationMilliseconds,
                    isExplicit: track.isExplicit,
                    isPlayable: track.isPlayable,
                    linkedFromID: track.linkedFromID,
                    uri: track.uri
                )
            } else {
                withArt = track
            }
            collected.append(withArt)
        }
    }

    /// Latest album and single releases first (by four-digit year when present).
    private static func albumsForTrackFallback(from albums: [SpotifyArtistAlbum], maxCount: Int = 6) -> [SpotifyArtistAlbum] {
        let deduped = Self.dedupeAlbums(albums).filter { $0.group == .album || $0.group == .single }
        let sorted = deduped.sorted { lhs, rhs in
            let ly = Int(lhs.releaseYear ?? "") ?? 0
            let ry = Int(rhs.releaseYear ?? "") ?? 0
            if ly != ry {
                return ly > ry
            }
            if lhs.totalTracks != rhs.totalTracks {
                return lhs.totalTracks < rhs.totalTracks
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return Array(sorted.prefix(max(0, maxCount)))
    }

    private static func dedupeAlbums(_ albums: [SpotifyArtistAlbum]) -> [SpotifyArtistAlbum] {
        var deduped: [SpotifyArtistAlbum] = []
        var seenIDs: Set<String> = []
        deduped.reserveCapacity(albums.count)
        for album in albums {
            guard !seenIDs.contains(album.id) else { continue }
            seenIDs.insert(album.id)
            deduped.append(album)
        }
        return deduped
    }

    private static func artistAlbumBatchSignature(artistID: String, market: String?, ids: [String]) -> String {
        let normalizedMarket: String = {
            let trimmed = market?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty ?? true) ? "from_token" : trimmed!
        }()
        return "\(artistID)|\(normalizedMarket)|\(ids.sorted().joined(separator: ","))"
    }

    private func shouldSkipBatchedAlbumsFallback(for key: ArtistTopTracksProbeKey, now: Date) -> Bool {
        guard let until = artistBatchedAlbumsCooldownUntil[key] else {
            return false
        }
        if until > now {
            return true
        }
        artistBatchedAlbumsCooldownUntil[key] = nil
        return false
    }

    private func shouldSkipFailedArtistAlbumBatch(signature: String, now: Date) -> Bool {
        guard let until = failedArtistAlbumBatchCooldownUntil[signature] else {
            return false
        }
        if until > now {
            return true
        }
        failedArtistAlbumBatchCooldownUntil[signature] = nil
        return false
    }

    @discardableResult
    private func registerBatchedAlbumsRateLimit(for key: ArtistTopTracksProbeKey, retryAfter: TimeInterval?, now: Date) -> Date {
        let cooldown = min(max(retryAfter ?? 12, 6), 300)
        let until = now.addingTimeInterval(cooldown)
        artistBatchedAlbumsCooldownUntil[key] = until
        return until
    }

    private func shouldProbeTopTracks(for key: ArtistTopTracksProbeKey, now: Date) -> Bool {
        guard let state = artistTopTracksProbeState[key] else {
            return true
        }
        switch state {
        case let .forbidden(until), let .rateLimited(until):
            if until > now {
                return false
            }
            artistTopTracksProbeState[key] = nil
            return true
        }
    }

    private func registerTopTracksProbeSuccess(for key: ArtistTopTracksProbeKey) {
        artistTopTracksProbeState[key] = nil
    }

    /// Records the probe failure state and returns the budget mode the album fallback should run under.
    /// Long-retry 429s map to `.skipped` so the album fallback short-circuits instead of stacking another
    /// outbound call onto an active back-off window.
    @discardableResult
    private func registerTopTracksProbeFailure(_ error: Error, for key: ArtistTopTracksProbeKey, now: Date) -> AlbumFallbackBudgetMode {
        guard let apiError = error as? SpotifyAPIError else {
            return .healthy
        }
        switch apiError {
        case .forbidden, .insufficientScope:
            artistTopTracksProbeState[key] = .forbidden(until: now.addingTimeInterval(6 * 60 * 60))
            return .healthy
        case let .rateLimited(retryAfter):
            let cooldown = min(max(retryAfter ?? 12, 6), 60)
            artistTopTracksProbeState[key] = .rateLimited(until: now.addingTimeInterval(cooldown))
            // Longer Retry-After values mean Spotify is actively throttling us; skipping the album fallback
            // here prevents `/v1/albums?ids=` from inheriting the same cooldown and burning the next slot.
            if let retryAfter, retryAfter > 5 {
                return .skipped
            }
            return .rateLimitedReduced
        case .unauthorized, .notFound, .badRequest, .server, .decoding, .network, .invalidRequest:
            return .healthy
        }
    }

    func refreshSelectedPlaylist() async {
        if let sidebarSelection {
            if case .pinnedItem = sidebarSelection {
                return
            }
            detailSession += 1
            let session = detailSession
            switch sidebarSelection {
            case .playlist(let playlistID):
                try? cache.invalidateTracks(playlistID: playlistID)
                lastTracksRevalidationByID[playlistID] = nil
            case .likedSongs:
                try? cache.invalidateTracks(playlistID: SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID)
                lastTracksRevalidationByID[SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID] = nil
            case .home, .pinnedItem:
                break
            }
            await scheduleDetailLoad(for: sidebarSelection, refreshCachedData: false, session: session)
        } else if let artistID = artistIDForRefreshingDetail {
            await selectArtist(id: artistID, forceRefresh: true, origin: .backStackReplay, displayName: nil)
        }
    }

    /// Reloads the playlist library list (sidebar) or the current detail surface (tracks / artist).
    func unifiedRefreshMainSurface() async {
        guard let selection = sidebarSelection else {
            await refreshSelectedPlaylist()
            return
        }
        switch selection {
        case .home:
            await refreshPlaylists(trigger: .userInitiated)
        case .likedSongs, .playlist, .pinnedItem:
            await refreshSelectedPlaylist()
        }
    }

    /// Single refresh entry for toolbar, ⌘R, and legacy palette bindings.
    func performUnifiedRefresh(queueRefresh: () async -> Void) async {
        if refreshRoutingLyricsPresented {
            await unifiedRefreshMainSurface()
            return
        }
        if refreshRoutingQueuePanelVisible, refreshRoutingQueuePanelFocused {
            isUnifiedQueueRefreshActive = true
            defer { isUnifiedQueueRefreshActive = false }
            await queueRefresh()
            return
        }
        await unifiedRefreshMainSurface()
    }

    /// When viewing an artist page (no playlist selection), refresh reloads that artist.
    private var artistIDForRefreshingDetail: String? {
        switch detailState {
        case let .loaded(content), let .staleCache(content, _), let .refreshing(content):
            if case let .artist(vm) = content {
                return vm.artist.id
            }
            return nil
        case .loading, .empty, .error:
            return nil
        }
    }

    func selectNextPlaylist() async {
        await selectAdjacentPlaylist(offset: 1)
    }

    func selectPreviousPlaylist() async {
        await selectAdjacentPlaylist(offset: -1)
    }

    func navigateBack() async {
        guard let target = popPreviousNavigationTarget() else {
            syncCanNavigateBack()
            return
        }
        if !breadcrumbPath.isEmpty {
            breadcrumbPath.removeLast()
        }
        isPerformingBackNavigation = true
        defer {
            isPerformingBackNavigation = false
            syncCanNavigateBack()
        }
        currentNavigationTarget = target
        switch target {
        case let .sidebar(selection):
            await selectSidebar(selection, origin: .backStackReplay)
        case let .artist(id):
            await selectArtist(id: id, forceRefresh: false, origin: .backStackReplay, displayName: nil)
        case let .album(id, title, subtitle, artworkURL):
            await selectAlbum(
                id: id,
                displayTitle: title,
                displaySubtitle: subtitle,
                artworkURL: artworkURL,
                origin: .backStackReplay
            )
        }
        reconcileBreadcrumbAfterNavigateBack(to: target)
    }

    func jumpToHome() async {
        breadcrumbPath = []
        backNavigationStack = []
        currentNavigationTarget = nil
        canNavigateBack = false
        isPerformingBackNavigation = true
        defer { isPerformingBackNavigation = false }
        await selectSidebar(.home, origin: .backStackReplay)
    }

    func jumpToBreadcrumb(at index: Int) async {
        guard index >= 0, index < breadcrumbPath.count else { return }
        breadcrumbPath = Array(breadcrumbPath.prefix(index + 1))
        let crumb = breadcrumbPath[index]
        backNavigationStack = []
        currentNavigationTarget = nil
        canNavigateBack = false
        isPerformingBackNavigation = true
        defer { isPerformingBackNavigation = false }
        switch crumb.kind {
        case .likedSongs:
            await selectSidebar(.likedSongs, origin: .backStackReplay)
        case let .playlist(id):
            await selectSidebar(.playlist(id), origin: .backStackReplay)
        case let .artist(id):
            await selectArtist(id: id, forceRefresh: false, origin: .backStackReplay, displayName: crumb.label)
        case let .album(id, title, subtitle, artworkURL):
            await selectAlbum(
                id: id,
                displayTitle: title,
                displaySubtitle: subtitle,
                artworkURL: artworkURL,
                origin: .backStackReplay
            )
        }
        syncCanNavigateBack()
    }

    func clearForSignOut() {
        adjacentPlaylistSelectionTask?.cancel()
        adjacentPlaylistSelectionTask = nil
        pendingAdjacentPlaylistOffset = 0
        detailLoadTask?.cancel()
        detailLoadTask = nil
        sidebarSelection = nil
        playlistsByID = [:]
        lastTracksRevalidationByID = [:]
        cachedArtistSnapshots = [:]
        currentArtistAlbumsPaging = nil
        artistTopTracksProbeState = [:]
        artistBatchedAlbumsCooldownUntil = [:]
        failedArtistAlbumBatchCooldownUntil = [:]
        attemptedArtistAlbumRecoveryIDs = []
        backNavigationStack = []
        currentNavigationTarget = nil
        canNavigateBack = false
        breadcrumbPath = []
        playlistState = .empty("Connect Spotify to browse playlists.")
        detailState = .empty("Sign in to Spotify to browse playlists and artists.")
    }

    private func registerNavigationTransition(to target: BrowserNavigationTarget) {
        if isPerformingBackNavigation {
            currentNavigationTarget = target
            syncCanNavigateBack()
            return
        }
        if currentNavigationTarget == nil {
            currentNavigationTarget = navigationTargetFromCurrentState()
        }
        guard currentNavigationTarget != target else {
            syncCanNavigateBack()
            return
        }
        if let currentNavigationTarget {
            backNavigationStack.append(currentNavigationTarget)
            if backNavigationStack.count > maxBackNavigationDepth {
                backNavigationStack.removeFirst(backNavigationStack.count - maxBackNavigationDepth)
            }
        }
        currentNavigationTarget = target
        syncCanNavigateBack()
    }

    private func popPreviousNavigationTarget() -> BrowserNavigationTarget? {
        while let previous = backNavigationStack.popLast() {
            if previous != currentNavigationTarget {
                return previous
            }
        }
        return nil
    }

    private func syncCanNavigateBack() {
        canNavigateBack = !backNavigationStack.isEmpty
    }

    private func applyBreadcrumbForSidebar(_ selection: SidebarSelection, origin: BrowserNavigationOrigin) {
        switch origin {
        case .backStackReplay:
            return
        case .reset, .extend:
            switch selection {
            case .home:
                breadcrumbPath = []
            case .likedSongs:
                breadcrumbPath = [
                    BrowserBreadcrumb(
                        id: UUID(),
                        label: "Liked Songs",
                        systemImage: "heart.fill",
                        kind: .likedSongs
                    )
                ]
            case let .playlist(id):
                let title = playlistsByID[id]?.name ?? "Playlist"
                breadcrumbPath = [
                    BrowserBreadcrumb(
                        id: UUID(),
                        label: title,
                        systemImage: "music.note.list",
                        kind: .playlist(id: id)
                    )
                ]
            case .pinnedItem:
                break
            }
        }
    }

    private func applyBreadcrumbForArtist(id: String, displayName: String?, origin: BrowserNavigationOrigin) {
        switch origin {
        case .backStackReplay:
            return
        case .reset:
            let label = resolvedArtistLabel(id: id, displayName: displayName)
            breadcrumbPath = [
                BrowserBreadcrumb(
                    id: UUID(),
                    label: label,
                    systemImage: "person.wave.2",
                    kind: .artist(id: id)
                )
            ]
        case .extend:
            let label = resolvedArtistLabel(id: id, displayName: displayName)
            appendOrTrimBreadcrumb(
                BrowserBreadcrumb(
                    id: UUID(),
                    label: label,
                    systemImage: "person.wave.2",
                    kind: .artist(id: id)
                )
            )
        }
    }

    private func applyBreadcrumbForAlbum(
        id: String,
        title: String,
        subtitle: String,
        artworkURL: URL?,
        origin: BrowserNavigationOrigin
    ) {
        switch origin {
        case .backStackReplay:
            return
        case .reset:
            breadcrumbPath = [
                BrowserBreadcrumb(
                    id: UUID(),
                    label: title,
                    systemImage: "opticaldisc",
                    kind: .album(id: id, title: title, subtitle: subtitle, artworkURL: artworkURL)
                )
            ]
        case .extend:
            appendOrTrimBreadcrumb(
                BrowserBreadcrumb(
                    id: UUID(),
                    label: title,
                    systemImage: "opticaldisc",
                    kind: .album(id: id, title: title, subtitle: subtitle, artworkURL: artworkURL)
                )
            )
        }
    }

    /// Prevents duplicate loops in the toolbar trail by collapsing to an
    /// already-visited page when users navigate to the same destination again.
    private func appendOrTrimBreadcrumb(_ crumb: BrowserBreadcrumb) {
        if let existingIndex = breadcrumbPath.lastIndex(where: { existing in
            breadcrumbRepresentsSamePage(existing.kind, crumb.kind)
        }) {
            breadcrumbPath = Array(breadcrumbPath.prefix(existingIndex + 1))
            return
        }
        breadcrumbPath.append(crumb)
    }

    /// Matches logical destination identity (IDs), not display metadata.
    private func breadcrumbRepresentsSamePage(_ lhs: BrowserBreadcrumb.Kind, _ rhs: BrowserBreadcrumb.Kind) -> Bool {
        switch (lhs, rhs) {
        case (.likedSongs, .likedSongs):
            return true
        case let (.playlist(leftID), .playlist(rightID)):
            return leftID == rightID
        case let (.artist(leftID), .artist(rightID)):
            return leftID == rightID
        case let (.album(leftID, _, _, _), .album(rightID, _, _, _)):
            return leftID == rightID
        default:
            return false
        }
    }

    private func resolvedArtistLabel(id: String, displayName: String?) -> String {
        if let displayName {
            let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let cached = cachedArtistSnapshots[id] {
            return cached.snapshot.artistDetail.name
        }
        return "Artist"
    }

    private func refineLastBreadcrumbArtistLabelIfNeeded(artistID: String, resolvedName: String) {
        guard let idx = breadcrumbPath.indices.last,
              case let .artist(aid) = breadcrumbPath[idx].kind,
              aid == artistID,
              breadcrumbPath[idx].label != resolvedName else { return }
        let old = breadcrumbPath[idx]
        breadcrumbPath[idx] = BrowserBreadcrumb(
            id: old.id,
            label: resolvedName,
            systemImage: old.systemImage,
            kind: old.kind
        )
    }

    /// After ``navigateBack()`` pops the leaf crumb, the path can be empty while the replayed
    /// destination still needs a single segment (e.g. switching playlists resets the trail to one crumb).
    private func reconcileBreadcrumbAfterNavigateBack(to target: BrowserNavigationTarget) {
        guard breadcrumbPath.isEmpty else { return }
        switch target {
        case let .sidebar(selection):
            applyBreadcrumbForSidebar(selection, origin: .reset)
        case let .artist(id):
            applyBreadcrumbForArtist(id: id, displayName: nil, origin: .reset)
        case let .album(id, title, subtitle, artworkURL):
            applyBreadcrumbForAlbum(
                id: id,
                title: title,
                subtitle: subtitle,
                artworkURL: artworkURL,
                origin: .reset
            )
        }
    }

    private func navigationTargetFromCurrentState() -> BrowserNavigationTarget? {
        if let detailAlbumTarget = albumNavigationTargetFromCurrentDetail() {
            return detailAlbumTarget
        }
        if let sidebarSelection {
            if case .pinnedItem = sidebarSelection {
                return nil
            }
            return .sidebar(sidebarSelection)
        }
        if let artistID = artistIDForRefreshingDetail {
            return .artist(artistID)
        }
        return nil
    }

    private func albumNavigationTargetFromCurrentDetail() -> BrowserNavigationTarget? {
        guard let content = detailState.currentValue,
              case let .playlist(detail) = content,
              detail.playlist.snapshotID.hasPrefix("album-") else {
            return nil
        }
        return .album(
            id: detail.playlist.id,
            title: detail.playlist.title,
            subtitle: detail.playlist.owner,
            artworkURL: detail.playlist.artworkURL
        )
    }

    private func loadDetail(for selection: SidebarSelection, refreshCachedData: Bool, session: Int) async {
        guard !Task.isCancelled else { return }
        switch selection {
        case .home:
            guard session == detailSession else { return }
            detailState = .empty("Home is not available yet.")
        case .likedSongs:
            await loadLikedSongsTracks(refreshCachedData: refreshCachedData, session: session)
        case let .playlist(playlistID):
            await loadTracks(for: playlistID, refreshCachedData: refreshCachedData, session: session)
        case .pinnedItem:
            guard session == detailSession else { return }
            return
        }
    }

    private func scheduleDetailLoad(for selection: SidebarSelection, refreshCachedData: Bool, session: Int) async {
        detailLoadTask?.cancel()
        detailLoadGeneration += 1
        let generation = detailLoadGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.loadDetail(for: selection, refreshCachedData: refreshCachedData, session: session)
        }
        detailLoadTask = task
        await task.value
        if generation == detailLoadGeneration {
            detailLoadTask = nil
        }
    }

    private func fetchPlaylistsForRefresh(trigger: PlaylistRefreshTrigger) async throws -> [SpotifyPlaylistSummary] {
        if let inFlightPlaylistListRefreshTask {
            return try await inFlightPlaylistListRefreshTask.value
        }

        if trigger == .userInitiated,
           let lastManualPlaylistRefreshAt,
           now().timeIntervalSince(lastManualPlaylistRefreshAt) < manualPlaylistRefreshCooldown,
           let cached = currentPlaylistSummariesFromLoadedState(),
           !cached.isEmpty {
            return cached
        }

        if trigger == .userInitiated {
            lastManualPlaylistRefreshAt = now()
        }

        playlistListRefreshGeneration += 1
        let generation = playlistListRefreshGeneration
        let task = Task { [api] in
            try await api.currentUserPlaylists(limit: 50)
        }
        inFlightPlaylistListRefreshTask = task
        do {
            let playlists = try await task.value
            if generation == playlistListRefreshGeneration {
                inFlightPlaylistListRefreshTask = nil
            }
            return playlists
        } catch {
            if generation == playlistListRefreshGeneration {
                inFlightPlaylistListRefreshTask = nil
            }
            throw error
        }
    }

    private func currentPlaylistSummariesFromLoadedState() -> [SpotifyPlaylistSummary]? {
        guard let rows = playlistState.currentValue, !rows.isEmpty else { return nil }
        let ordered = rows.compactMap { playlistsByID[$0.id] }
        return ordered.isEmpty ? nil : ordered
    }

    private func loadLikedSongsTracks(refreshCachedData: Bool, session: Int) async {
        guard !Task.isCancelled else { return }
        guard session == detailSession else { return }
        let virtualID = SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID
        let snapshotID = SpotiglassSidebarLibrary.likedSongsCacheSnapshotID

        if refreshCachedData,
           let cachedTracks = try? cache.loadTracks(playlistID: virtualID, snapshotID: snapshotID, now: now(), maxAge: maxCacheAge) {
            await setLikedSongsDetailState(from: cachedTracks)
            if shouldSkipAutomaticLikedSongsRevalidation() {
                return
            }
            if let last = lastTracksRevalidationByID[virtualID],
               last.snapshotID == snapshotID,
               now().timeIntervalSince(last.at) < tracksRevalidateMinInterval {
                return
            }
            await revalidateLikedSongs(session: session)
            return
        }

        if refreshCachedData,
           let staleTracks = try? cache.loadTracksIgnoringAge(playlistID: virtualID, snapshotID: snapshotID) {
            await setLikedSongsDetailState(from: staleTracks)
            if let existingDetail = detailState.currentValue {
                detailState = .refreshing(existingDetail)
            }
            await revalidateLikedSongs(session: session)
            return
        }

        let existingDetail = detailState.currentValue
        detailState = .loading
        guard session == detailSession else { return }
        if let existingDetail {
            detailState = .refreshing(existingDetail)
        }
        await revalidateLikedSongs(session: session)
    }

    private func setLikedSongsDetailState(from tracks: [SpotifyPlaylistTrackItem]) async {
        if tracks.isEmpty {
            detailState = .empty("You have no liked songs yet.")
            return
        }
        let profile = try? await api.currentUserProfile()
        let trimmedName = profile?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let owner = trimmedName.isEmpty ? "You" : trimmedName
        let row = PlaylistRowViewModel(
            likedSongsOwnerDisplay: owner,
            totalTrackCount: tracks.count,
            artworkURL: firstLikedSongsArtwork(from: tracks)
        )
        detailState = .loaded(.playlist(PlaylistDetailViewModel(playlist: row, tracks: TrackRowViewModel.numberedPlaylistRows(tracks))))
    }

    private func firstLikedSongsArtwork(from tracks: [SpotifyPlaylistTrackItem]) -> URL? {
        for item in tracks.prefix(4) {
            if case let .track(t) = item.content { return t.albumArtworkURL }
            if case let .episode(e) = item.content { return e.artworkURL }
        }
        return nil
    }

    private func revalidateLikedSongs(session: Int) async {
        do {
            let result = try await likedSongsRevalidationResult()
            try? cache.saveTracks(
                result.tracks,
                playlistID: SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID,
                snapshotID: SpotiglassSidebarLibrary.likedSongsCacheSnapshotID,
                cachedAt: now()
            )
            lastLikedSongsRevalidationAt = now()
            lastTracksRevalidationByID[SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID] = (
                SpotiglassSidebarLibrary.likedSongsCacheSnapshotID,
                now()
            )
            guard session == detailSession else { return }
            let profile = try? await api.currentUserProfile()
            let trimmedName = profile?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let owner = trimmedName.isEmpty ? "You" : trimmedName
            let row = PlaylistRowViewModel(
                likedSongsOwnerDisplay: owner,
                totalTrackCount: max(result.totalAvailable, result.tracks.count),
                artworkURL: firstLikedSongsArtwork(from: result.tracks)
            )
            if result.tracks.isEmpty {
                detailState = .empty("You have no liked songs yet.")
            } else {
                detailState = .loaded(.playlist(PlaylistDetailViewModel(playlist: row, tracks: TrackRowViewModel.numberedPlaylistRows(result.tracks))))
            }
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            guard session == detailSession else { return }
            let displayError = Self.displayError(for: error)
            if let existingDetail = detailState.currentValue {
                detailState = .staleCache(existingDetail, displayError)
            } else {
                detailState = .error(displayError)
            }
        }
    }

    private func shouldSkipAutomaticLikedSongsRevalidation() -> Bool {
        guard likedSongsRevalidationTask == nil,
              let lastRevalidation = lastLikedSongsRevalidationAt else {
            return false
        }
        return now().timeIntervalSince(lastRevalidation) < likedSongsAutoRefreshMinInterval
    }

    private func likedSongsRevalidationResult() async throws -> SpotifySavedTracksResult {
        if let inFlight = likedSongsRevalidationTask {
            return try await inFlight.value
        }
        let task = Task { [api] in
            try await api.currentUserSavedTracks(limit: 50, maxPages: 20)
        }
        likedSongsRevalidationTask = task
        defer { likedSongsRevalidationTask = nil }
        return try await task.value
    }

    private func loadTracks(for playlistID: String, refreshCachedData: Bool, session: Int) async {
        guard !Task.isCancelled else { return }
        guard session == detailSession else { return }
        guard let playlist = playlistsByID[playlistID] else {
            detailState = .error(BrowsingDisplayError(
                title: "Playlist unavailable",
                message: "This playlist disappeared or is no longer accessible.",
                canRetry: true
            ))
            return
        }

        let playlistRow = PlaylistRowViewModel(playlist)

        if refreshCachedData,
           let cachedTracks = try? cache.loadTracks(playlistID: playlist.id, snapshotID: playlist.snapshotID, now: now(), maxAge: maxCacheAge) {
            if cachedTracks.isEmpty {
                detailState = .empty("This playlist has no tracks.")
            } else {
                detailState = .loaded(.playlist(PlaylistDetailViewModel(playlist: playlistRow, tracks: TrackRowViewModel.numberedPlaylistRows(cachedTracks))))
            }
            if let last = lastTracksRevalidationByID[playlist.id],
               last.snapshotID == playlist.snapshotID,
               now().timeIntervalSince(last.at) < tracksRevalidateMinInterval {
                return
            }
            await revalidatePlaylistTracks(playlist: playlist, playlistRow: playlistRow, session: session)
            return
        }

        if refreshCachedData,
           let staleTracks = try? cache.loadTracksIgnoringAge(playlistID: playlist.id, snapshotID: playlist.snapshotID) {
            if staleTracks.isEmpty {
                detailState = .empty("This playlist has no tracks.")
            } else {
                detailState = .loaded(.playlist(PlaylistDetailViewModel(playlist: playlistRow, tracks: TrackRowViewModel.numberedPlaylistRows(staleTracks))))
            }
            if let existingDetail = detailState.currentValue {
                detailState = .refreshing(existingDetail)
            }
            await revalidatePlaylistTracks(playlist: playlist, playlistRow: playlistRow, session: session)
            return
        }

        let existingDetail = detailState.currentValue
        detailState = .loading
        guard session == detailSession else { return }
        if let existingDetail {
            detailState = .refreshing(existingDetail)
        }
        await revalidatePlaylistTracks(playlist: playlist, playlistRow: playlistRow, session: session)
    }

    private func revalidatePlaylistTracks(playlist: SpotifyPlaylistSummary, playlistRow: PlaylistRowViewModel, session: Int) async {
        do {
            // Spotify's `/v1/playlists/{id}/items` endpoint accepts a maximum
            // limit of 50 (the February 2026 rename also tightened the cap from
            // the legacy `/tracks` endpoint's 100). Passing 100 yields HTTP 400
            // invalid_request and breaks any playlist with more than 50 tracks.
            let tracks = try await api.playlistTracks(playlistID: playlist.id, limit: 50, maxPages: 200)
            try? cache.saveTracks(tracks, playlistID: playlist.id, snapshotID: playlist.snapshotID, cachedAt: now())
            lastTracksRevalidationByID[playlist.id] = (playlist.snapshotID, now())
            guard session == detailSession else { return }
            if tracks.isEmpty {
                detailState = .empty("This playlist has no tracks.")
            } else {
                detailState = .loaded(.playlist(PlaylistDetailViewModel(playlist: playlistRow, tracks: TrackRowViewModel.numberedPlaylistRows(tracks))))
            }
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            guard session == detailSession else { return }
            let displayError = Self.displayError(for: error)
            if let existingDetail = detailState.currentValue {
                detailState = .staleCache(existingDetail, displayError)
            } else {
                detailState = .error(displayError)
            }
        }
    }

    private func selectAdjacentPlaylist(offset: Int) async {
        pendingAdjacentPlaylistOffset += offset
        adjacentPlaylistSelectionTask?.cancel()
        adjacentPlaylistSelectionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled else { return }
            let order: [SidebarSelection] = [.home, .likedSongs] + self.visiblePlaylists.map { .playlist($0.id) }
            guard !order.isEmpty else { return }
            let delta = self.pendingAdjacentPlaylistOffset
            self.pendingAdjacentPlaylistOffset = 0
            let currentIndex = order.firstIndex(of: self.sidebarSelection ?? .home) ?? 0
            let nextIndex = min(max(0, currentIndex + delta), order.count - 1)
            let target = order[nextIndex]
            await self.selectSidebar(target)
        }
        await adjacentPlaylistSelectionTask?.value
    }

    private func apply(
        playlists: [SpotifyPlaylistSummary],
        state: BrowsingLoadState<[PlaylistRowViewModel]>,
        preserveSelection: Bool
    ) {
        playlistsByID = Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, $0) })
        playlistState = state

        if preserveSelection, let selection = sidebarSelection {
            switch selection {
            case let .playlist(id) where playlistsByID[id] != nil:
                return
            case .likedSongs, .home, .pinnedItem:
                return
            case .playlist:
                break
            }
        }

        if case let .playlist(missingID) = sidebarSelection, playlistsByID[missingID] == nil {
            detailState = .error(BrowsingDisplayError(
                title: "Playlist unavailable",
                message: "The selected playlist was deleted or is no longer accessible.",
                canRetry: true
            ))
        }
        sidebarSelection = playlists.first.map { .playlist($0.id) }
    }

    static func displayError(for error: Error) -> BrowsingDisplayError {
        if let apiError = error as? SpotifyAPIError {
            switch apiError {
            case .unauthorized:
                return BrowsingDisplayError(title: "Sign in again", message: "Your Spotify sign-in expired. Disconnect and connect Spotify again.", canRetry: false)
            case .insufficientScope:
                return BrowsingDisplayError(
                    title: "Reconnect Spotify",
                    message: "Your current Spotify session is missing playlist or Liked Songs permissions. Disconnect and connect again to grant required scopes.",
                    canRetry: false,
                    diagnosticDetails: apiError.diagnosticDetails
                )
            case let .forbidden(message, _):
                return BrowsingDisplayError(
                    title: "Access denied",
                    message: message ?? "Spotify denied access to this resource.",
                    canRetry: false,
                    diagnosticDetails: apiError.diagnosticDetails
                )
            case let .rateLimited(retryAfter):
                let clause = SpotifyRateLimitDisplay.retryAfterClause(seconds: retryAfter)
                return BrowsingDisplayError(
                    title: "Spotify is rate limiting requests",
                    message: "Too many requests were sent to Spotify. \(clause)",
                    canRetry: true,
                    diagnosticDetails: SpotifyRateLimitDisplay.rawRetryDiagnostic(seconds: retryAfter)
                )
            case let .notFound(message):
                return BrowsingDisplayError(title: "Not found", message: message ?? "This Spotify resource is no longer available.", canRetry: true)
            case let .network(message):
                return BrowsingDisplayError(title: "Network unavailable", message: message, canRetry: true)
            case .decoding:
                return BrowsingDisplayError(title: "Could not read Spotify response", message: apiError.userMessage, canRetry: true)
            case let .badRequest(message, _):
                return BrowsingDisplayError(
                    title: "Spotify rejected the request",
                    message: message ?? "Spotify rejected this request.",
                    canRetry: false,
                    diagnosticDetails: apiError.diagnosticDetails
                )
            case let .server(_, message, _):
                return BrowsingDisplayError(
                    title: "Spotify service issue",
                    message: message ?? "Spotify returned a server error.",
                    canRetry: true,
                    diagnosticDetails: apiError.diagnosticDetails
                )
            case let .invalidRequest(message):
                return BrowsingDisplayError(title: "Invalid request", message: message, canRetry: false)
            }
        }

        return BrowsingDisplayError(title: "Something went wrong", message: error.localizedDescription, canRetry: true)
    }
}

private struct ArtistTopTracksProbeKey: Hashable {
    let artistID: String
    let market: String

    init(artistID: String, market: String?) {
        self.artistID = artistID
        self.market = market ?? "from_token"
    }
}

private enum ArtistTopTracksProbeState {
    case forbidden(until: Date)
    case rateLimited(until: Date)
}

private enum AlbumFallbackBudgetMode: Equatable {
    /// Top-tracks succeeded or returned a non-429 error; full fallback budget available.
    case healthy
    /// Short rate-limit retry-after; album fallback runs with reduced ID/recovery budget.
    case rateLimitedReduced
    /// Long rate-limit retry-after; skip album fallback entirely to avoid stacking on the back-off window.
    case skipped
}

private struct ArtistAlbumFallbackStrategy {
    /// Number of album IDs sent to the batched `GET /v1/albums?ids=...` call.
    let maxAlbumRequests: Int
    /// Hard ceiling on follow-up single-album recovery `/v1/albums/{id}/tracks` calls (0 or 1).
    let maxRecoveryCalls: Int

    init(rateLimited: Bool) {
        if rateLimited {
            self.maxAlbumRequests = 3
            self.maxRecoveryCalls = 0
        } else {
            self.maxAlbumRequests = 6
            self.maxRecoveryCalls = 1
        }
    }
}

private struct DisabledSpotifyBrowsingCache: SpotifyBrowsingCache {
    func loadPlaylists(now: Date, maxAge: TimeInterval) throws -> [SpotifyPlaylistSummary]? { nil }
    func loadPlaylistsBundle(now: Date) throws -> (playlists: [SpotifyPlaylistSummary], age: TimeInterval)? { nil }
    func savePlaylists(_ playlists: [SpotifyPlaylistSummary], cachedAt: Date) throws {}
    func loadTracks(playlistID: String, snapshotID: String, now: Date, maxAge: TimeInterval) throws -> [SpotifyPlaylistTrackItem]? { nil }
    func loadTracksIgnoringAge(playlistID: String, snapshotID: String) throws -> [SpotifyPlaylistTrackItem]? { nil }
    func saveTracks(_ tracks: [SpotifyPlaylistTrackItem], playlistID: String, snapshotID: String, cachedAt: Date) throws {}
    func invalidateTracks(playlistID: String) throws {}
}
