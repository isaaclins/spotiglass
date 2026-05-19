import Foundation

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

    /// `internal(set)` so split extensions in other files can update state (`private(set)` is file-private).
    @Published internal(set) var playlistState: BrowsingLoadState<[PlaylistRowViewModel]> = .loading
    @Published internal(set) var detailState: BrowsingLoadState<BrowsingDetailContent> = .empty("Select an item in the sidebar or open an artist from search.")
    @Published var sidebarSelection: SidebarSelection?
    @Published internal(set) var canNavigateBack = false
    /// Logical drill-in path for the principal toolbar; empty at Home.
    @Published internal(set) var breadcrumbPath: [BrowserBreadcrumb] = []

    /// Immersive lyrics cover the window; unified refresh targets the underlying browser surface.
    var refreshRoutingLyricsPresented = false
    /// Playback queue panel visibility; synced from the browser view.
    var refreshRoutingQueuePanelVisible = false
    /// Whether the queue column owns refresh focus (⌘R / toolbar); synced from the browser view.
    var refreshRoutingQueuePanelFocused = false
    /// True only during a user-initiated queue refresh from the unified control (not background polling).
    @Published internal(set) var isUnifiedQueueRefreshActive = false

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

    let api: SpotifyBrowsingAPI
    let cache: SpotifyBrowsingCache
    let now: () -> Date
    let maxCacheAge: TimeInterval
    /// When the saved playlist list is younger than this, `load()` does not call `refreshPlaylists()` (tracks for the selection still revalidate in the background when a track cache hit exists).
    let playlistListAutoRefreshMinInterval: TimeInterval
    /// Skip background `/items` revalidation when disk cache is fresh and this playlist was revalidated recently with the same snapshot.
    let tracksRevalidateMinInterval: TimeInterval
    /// Cool-down for user-initiated Home refreshes to avoid bursty list reloads.
    let manualPlaylistRefreshCooldown: TimeInterval
    /// Short cool-down for automatic liked-songs revalidation when cache is already fresh.
    let likedSongsAutoRefreshMinInterval: TimeInterval
    /// TTL for artist detail soft cache to prevent bursty repeated full refetches.
    let artistDetailCacheTTL: TimeInterval
    /// Number of artist album pages to load initially before exposing "Load more".
    let initialArtistAlbumPageCount: Int
    internal(set) var playlistsByID: [String: SpotifyPlaylistSummary] = [:]
    var hasLoaded = false
    var detailSession = 0
    var detailLoadTask: Task<Void, Never>?
    var detailLoadGeneration = 0
    var adjacentPlaylistSelectionTask: Task<Void, Never>?
    var pendingAdjacentPlaylistOffset: Int = 0
    var lastTracksRevalidationByID: [String: (snapshotID: String, at: Date)] = [:]
    var inFlightPlaylistListRefreshTask: Task<[SpotifyPlaylistSummary], Error>?
    var playlistListRefreshGeneration = 0
    var lastManualPlaylistRefreshAt: Date?
    /// Collapses concurrent liked-songs refresh triggers into one network run.
    var likedSongsRevalidationTask: Task<SpotifySavedTracksResult, Error>?
    var lastLikedSongsRevalidationAt: Date?
    /// In-flight bulk "Load all your songs into Spotiglass" prefetch run. Holding the
    /// task lets the same command toggle cancellation on re-invocation.
    var prefetchAllPlaylistsTask: Task<Void, Never>?
    /// Published progress for the bulk prefetch run. Mirrored onto the command
    /// palette view-model by the view-side binding so the palette header can
    /// render "Loading N of M playlists…".
    @Published internal(set) var prefetchAllPlaylistsProgress: PrefetchAllPlaylistsProgress?
    var artistDetailLoadTasks: [String: Task<ArtistDetailSnapshot, Error>] = [:]
    internal(set) var cachedArtistSnapshots: [String: CachedArtistSnapshot] = [:]
    var currentArtistAlbumsPaging: ArtistAlbumsPagingState?
    var lastArtistSelectionAt: [String: Date] = [:]
    let artistSelectionDebounceWindow: TimeInterval = 0.4
    internal(set) var artistFetchMetrics = ArtistFetchMetrics()
    /// Clears sidebar selection when opening an artist; SwiftUI then calls `selectSidebar(nil)`, which must not reset the detail pane or bump `detailSession`.
    var ignoreNextNilSidebarSelectionForDetail = false
    var backNavigationStack: [BrowserNavigationTarget] = []
    var currentNavigationTarget: BrowserNavigationTarget?
    var isPerformingBackNavigation = false
    let maxBackNavigationDepth = 40

    let artistFallbackCooldown = ArtistFallbackCooldownStore()

    struct ArtistDetailSnapshot {
        let artistDetail: SpotifyArtistDetail
        let albums: [SpotifyArtistAlbum]
        let tracks: [SpotifyTrack]
        let usedStaleCache: Bool
        let paging: ArtistAlbumsPagingState?
    }

    struct CachedArtistSnapshot {
        let snapshot: ArtistDetailSnapshot
        let fetchedAt: Date
    }

    struct ArtistAlbumsPagingState {
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

    func clearForSignOut() {
        adjacentPlaylistSelectionTask?.cancel()
        adjacentPlaylistSelectionTask = nil
        pendingAdjacentPlaylistOffset = 0
        detailLoadTask?.cancel()
        detailLoadTask = nil
        prefetchAllPlaylistsTask?.cancel()
        prefetchAllPlaylistsTask = nil
        prefetchAllPlaylistsProgress = nil
        sidebarSelection = nil
        playlistsByID = [:]
        lastTracksRevalidationByID = [:]
        cachedArtistSnapshots = [:]
        currentArtistAlbumsPaging = nil
        artistFallbackCooldown.reset()
        backNavigationStack = []
        currentNavigationTarget = nil
        canNavigateBack = false
        breadcrumbPath = []
        playlistState = .empty("Connect Spotify to browse playlists.")
        detailState = .empty("Sign in to Spotify to browse playlists and artists.")
    }
}

private struct DisabledSpotifyBrowsingCache: SpotifyBrowsingCache {
    func loadPlaylistsBundle(now: Date) throws -> (playlists: [SpotifyPlaylistSummary], age: TimeInterval)? { nil }
    func savePlaylists(_ playlists: [SpotifyPlaylistSummary], cachedAt: Date) throws {}
    func loadTracks(playlistID: String, snapshotID: String, now: Date, maxAge: TimeInterval) throws -> [SpotifyPlaylistTrackItem]? { nil }
    func loadTracksIgnoringAge(playlistID: String, snapshotID: String) throws -> [SpotifyPlaylistTrackItem]? { nil }
    func saveTracks(_ tracks: [SpotifyPlaylistTrackItem], playlistID: String, snapshotID: String, cachedAt: Date) throws {}
    func invalidateTracks(playlistID: String) throws {}
}
