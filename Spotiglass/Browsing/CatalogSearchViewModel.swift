import Foundation

/// Category pills in the dedicated catalog Search view. `all` renders every
/// section as a preview; any other case renders that one section in full.
enum CatalogSearchCategory: String, CaseIterable, Identifiable, Hashable {
    case all
    case tracks
    case albums
    case artists
    case playlists

    var id: String { rawValue }

    var pillLabel: String {
        switch self {
        case .all: SpotiglassL10n.string("search.category.all")
        case .tracks: SpotiglassL10n.string("search.category.tracks")
        case .albums: SpotiglassL10n.string("search.category.albums")
        case .artists: SpotiglassL10n.string("search.category.artists")
        case .playlists: SpotiglassL10n.string("search.category.playlists")
        }
    }

    /// Maps the palette's footer scope onto a pill so the "Show all results"
    /// handoff lands on the same category the user was already filtering by.
    /// Palette-only scopes (`here`, `my playlists`) have no catalog equivalent
    /// and fall back to `all`.
    static func fromPaletteCategory(_ category: CommandPaletteSearchCategory) -> CatalogSearchCategory {
        switch category {
        case .tracks: .tracks
        case .artists: .artists
        case .all, .thisPlaylist, .myPlaylists: .all
        }
    }
}

/// One page of `/v1/search` mapped into the row/card models the browser already renders.
struct CatalogSearchResults: Equatable {
    var tracks: [TrackRowViewModel] = []
    var artists: [SpotifyArtist] = []
    var albums: [SpotifyAlbum] = []
    var playlists: [SpotifyPlaylistSummary] = []

    var isEmpty: Bool {
        tracks.isEmpty && artists.isEmpty && albums.isEmpty && playlists.isEmpty
    }

    /// Results narrowed to one pill. `all` keeps everything.
    func filtered(to category: CatalogSearchCategory) -> CatalogSearchResults {
        switch category {
        case .all: self
        case .tracks: CatalogSearchResults(tracks: tracks)
        case .albums: CatalogSearchResults(albums: albums)
        case .artists: CatalogSearchResults(artists: artists)
        case .playlists: CatalogSearchResults(playlists: playlists)
        }
    }
}

private extension SpotifySearchResults {
    func paging(for category: CatalogSearchCategory) -> SpotifySearchPaging? {
        switch category {
        case .all: nil
        case .tracks: tracksPaging
        case .artists: artistsPaging
        case .albums: albumsPaging
        case .playlists: playlistsPaging
        }
    }

    func itemCount(for category: CatalogSearchCategory) -> Int {
        switch category {
        case .all: tracks.count + artists.count + albums.count + playlists.count
        case .tracks: tracks.count
        case .artists: artists.count
        case .albums: albums.count
        case .playlists: playlists.count
        }
    }
}

/// Backing model for the full-window catalog Search view.
///
/// Deliberately independent of ``CommandPaletteViewModel``: the palette stays the
/// fast keyboard jump layer, this owns the browsable surface. The one thing they
/// share is the minimum query length, so both surfaces make identical decisions
/// about when a keystroke is worth a `/v1/search` round trip.
@MainActor
final class CatalogSearchViewModel: ObservableObject {
    /// Same gate the command palette uses. Reused rather than redeclared so
    /// tuning `/v1/search` traffic stays a one-line change in one place.
    static var minimumQueryCharacters: Int {
        CommandPaletteViewModel.minimumPaletteSearchQueryCharacters
    }

    /// Keystroke settle time before the network call. Matches the palette's debounce.
    static let debounceMilliseconds = 200

    /// `GET /v1/search` caps `limit` at 10 per item type, so a fuller single-category
    /// list is built from offset pages instead of one oversized request.
    static let pageSize = 10
    /// Pages fetched when a single category is selected (10 * 3 = 30 rows).
    static let focusedCategoryPageCount = 3

    @Published var query = ""
    @Published private(set) var category: CatalogSearchCategory = .all
    @Published private(set) var state: BrowsingLoadState<CatalogSearchResults> = .empty("")

    /// Injected by the browser view so this model never owns an API client.
    /// Parameters are the trimmed query, paging offset, and cache policy for the run.
    var searchProvider: (String, Int, SpotifyRequestCacheMode) async throws -> SpotifySearchResults = { _, _, _ in
        SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
    }

    private var searchTask: Task<Void, Never>?
    /// Monotonically identifies the latest scheduled query or refresh.
    private var searchGeneration = 0
    /// Query the cached page set belongs to; lets pill switches re-filter without refetching.
    private var cachedQuery: String?
    private var cachedPageCount = 0
    private var cachedResults: CatalogSearchResults?
    private var cachedRawTracks: [SpotifyTrack] = []
    private var cachedHasMore: [CatalogSearchCategory: Bool] = [:]
    private var cachedNextOffsets: [CatalogSearchCategory: Int] = [:]
    @Published private(set) var isLoadingMore = false

    deinit {
        searchTask?.cancel()
    }

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True once the query is long enough to be worth a network round trip.
    var meetsMinimumQueryLength: Bool {
        trimmedQuery.count >= Self.minimumQueryCharacters
    }

    /// Sections to render for the active pill.
    var visibleResults: CatalogSearchResults {
        (state.currentValue ?? CatalogSearchResults()).filtered(to: category)
    }

    /// True when the focused category has another Spotify page available.
    var canLoadMore: Bool {
        guard category != .all,
              !isLoadingMore,
              cachedQuery == trimmedQuery,
              cachedResults != nil,
              cachedPageCount >= pageCount(for: category) else {
            return false
        }
        return cachedHasMore[category] == true
    }

    // MARK: - Input

    /// Call from the search field's `onChange`.
    func queryDidChange() {
        scheduleSearch()
    }

    func selectCategory(_ newCategory: CatalogSearchCategory) {
        guard newCategory != category else { return }
        category = newCategory
        // A focused pill wants deeper paging than the `all` preview, so only
        // refetch when the cache cannot already satisfy the new page depth.
        if cachedQuery == trimmedQuery,
           let cachedResults,
           cachedPageCount >= pageCount(for: newCategory) {
            searchGeneration += 1
            isLoadingMore = false
            state = cachedResults.isEmpty
                ? .empty(SpotiglassL10n.format("search.empty.noResults", trimmedQuery))
                : .loaded(cachedResults)
            return
        }
        scheduleSearch()
    }

    func clearQuery() {
        query = ""
        scheduleSearch()
    }

    /// Explicit user refresh. Unlike query changes and category switches, this
    /// must discard the in-memory result and bypass the HTTP response cache.
    func refreshSearch() {
        scheduleSearch(forceRefresh: true)
    }

    /// Palette handoff: opens this view pre-populated with the palette's query and scope.
    func applyHandoff(query newQuery: String, paletteCategory: CommandPaletteSearchCategory) {
        query = newQuery
        category = CatalogSearchCategory.fromPaletteCategory(paletteCategory)
        scheduleSearch()
    }

    /// Loads one continuation page for the focused category and appends it to
    /// the current result set. Ordinary paging keeps the fresh-cache policy.
    func loadMore() async {
        guard canLoadMore,
              let queryToLoad = cachedQuery,
              let existingResults = cachedResults,
              let offset = cachedNextOffsets[category] else {
            return
        }

        let generation = searchGeneration
        let categoryBeingLoaded = category
        isLoadingMore = true
        state = .refreshing(existingResults)
        defer {
            if generation == searchGeneration {
                isLoadingMore = false
            }
        }

        do {
            let page = try await searchProvider(queryToLoad, offset, .freshOnly)
            try Task.checkCancellation()
            guard generation == searchGeneration,
                  category == categoryBeingLoaded,
                  self.cachedQuery == queryToLoad else {
                return
            }

            var merged = existingResults
            var tracks = cachedRawTracks
            appendUniqueTracks(from: page, to: &tracks)
            appendUniqueArtists(from: page, to: &merged)
            appendUniqueAlbums(from: page, to: &merged)
            appendUniquePlaylists(from: page, to: &merged)
            merged.tracks = TrackRowViewModel.numberedTopTracks(tracks)

            let fetchedPageCount = max(cachedPageCount, offset / Self.pageSize + 1)
            cachedPageCount = fetchedPageCount
            cachedRawTracks = tracks
            updatePagingState(from: page, offset: offset)
            cachedResults = merged
            state = merged.isEmpty
                ? .empty(SpotiglassL10n.format("search.empty.noResults", queryToLoad))
                : .loaded(merged)
        } catch is CancellationError {
            return
        } catch {
            guard generation == searchGeneration, !Task.isCancelled else { return }
            state = .staleCache(existingResults, PlaylistBrowserViewModel.displayError(for: error))
        }
    }

    // MARK: - Search

    private func pageCount(for category: CatalogSearchCategory) -> Int {
        category == .all ? 1 : Self.focusedCategoryPageCount
    }

    /// Debounces, then fetches. Queries below ``minimumQueryCharacters`` never
    /// reach ``searchProvider``.
    func scheduleSearch(forceRefresh: Bool = false) {
        searchTask?.cancel()
        isLoadingMore = false
        searchGeneration += 1
        let generation = searchGeneration
        let trimmed = trimmedQuery
        guard !trimmed.isEmpty else {
            resetCache()
            state = .empty(SpotiglassL10n.string("search.empty.prompt"))
            return
        }
        guard trimmed.count >= Self.minimumQueryCharacters else {
            resetCache()
            state = .empty(SpotiglassL10n.string("search.empty.keepTyping"))
            return
        }
        if forceRefresh {
            resetCache()
        } else if cachedQuery == trimmed, let cachedResults, cachedPageCount >= pageCount(for: category) {
            state = cachedResults.isEmpty
                ? .empty(SpotiglassL10n.format("search.empty.noResults", trimmed))
                : .loaded(cachedResults)
            return
        }

        state = .loading
        let pages = pageCount(for: category)
        let cacheMode: SpotifyRequestCacheMode = forceRefresh ? .bypassCache : .freshOnly
        searchTask = Task { [weak self] in
            guard let self else { return }
            await self.performSearch(
                query: trimmed,
                pageCount: pages,
                cacheMode: cacheMode,
                generation: generation
            )
        }
    }

    // periphery:ignore
    internal func waitForSearchCompletion() async {
        await searchTask?.value
    }

    private func performSearch(
        query trimmed: String,
        pageCount pages: Int,
        cacheMode: SpotifyRequestCacheMode,
        generation: Int
    ) async {
        do {
            try await Task.sleep(for: .milliseconds(Self.debounceMilliseconds))
            try Task.checkCancellation()

            var merged = CatalogSearchResults()
            var tracks: [SpotifyTrack] = []
            var hasMoreByCategory: [CatalogSearchCategory: Bool] = [:]
            var nextOffsets: [CatalogSearchCategory: Int] = [:]
            var pagesFetched = 0

            for pageIndex in 0 ..< max(1, pages) {
                let offset = pageIndex * Self.pageSize
                let results = try await searchProvider(trimmed, offset, cacheMode)
                try Task.checkCancellation()
                pagesFetched = pageIndex + 1
                appendUniqueTracks(from: results, to: &tracks)
                appendUniqueArtists(from: results, to: &merged)
                appendUniqueAlbums(from: results, to: &merged)
                appendUniquePlaylists(from: results, to: &merged)
                updatePagingState(
                    from: results,
                    offset: offset,
                    hasMoreByCategory: &hasMoreByCategory,
                    nextOffsets: &nextOffsets
                )

                let pageIsEmpty = results.tracks.isEmpty
                    && results.artists.isEmpty
                    && results.albums.isEmpty
                    && results.playlists.isEmpty
                if pageIsEmpty || (category != .all && hasMoreByCategory[category] == false) {
                    break
                }
            }
            guard generation == searchGeneration, !Task.isCancelled else { return }
            merged.tracks = TrackRowViewModel.numberedTopTracks(tracks)

            cachedQuery = trimmed
            cachedPageCount = pagesFetched
            cachedRawTracks = tracks
            cachedHasMore = hasMoreByCategory
            cachedNextOffsets = nextOffsets
            cachedResults = merged
            state = merged.isEmpty
                ? .empty(SpotiglassL10n.format("search.empty.noResults", trimmed))
                : .loaded(merged)
        } catch is CancellationError {
            return
        } catch {
            guard generation == searchGeneration, !Task.isCancelled else { return }
            resetCache()
            state = .error(PlaylistBrowserViewModel.displayError(for: error))
        }
    }

    private func appendUniqueTracks(from page: SpotifySearchResults, to tracks: inout [SpotifyTrack]) {
        var seenIDs = Set(tracks.map(\.id))
        for track in page.tracks where seenIDs.insert(track.id).inserted {
            tracks.append(track)
        }
    }

    private func appendUniqueArtists(from page: SpotifySearchResults, to results: inout CatalogSearchResults) {
        var seenIDs = Set(results.artists.map(\.id))
        for artist in page.artists where seenIDs.insert(artist.id).inserted {
            results.artists.append(artist)
        }
    }

    private func appendUniqueAlbums(from page: SpotifySearchResults, to results: inout CatalogSearchResults) {
        var seenIDs = Set(results.albums.map(\.id))
        for album in page.albums where seenIDs.insert(album.id).inserted {
            results.albums.append(album)
        }
    }

    private func appendUniquePlaylists(from page: SpotifySearchResults, to results: inout CatalogSearchResults) {
        var seenIDs = Set(results.playlists.map(\.id))
        for playlist in page.playlists where seenIDs.insert(playlist.id).inserted {
            results.playlists.append(playlist)
        }
    }

    private func updatePagingState(
        from results: SpotifySearchResults,
        offset: Int,
        hasMoreByCategory: inout [CatalogSearchCategory: Bool],
        nextOffsets: inout [CatalogSearchCategory: Int]
    ) {
        for pagedCategory in CatalogSearchCategory.allCases where pagedCategory != .all {
            let hasMore = hasMore(in: results, category: pagedCategory, offset: offset)
            hasMoreByCategory[pagedCategory] = hasMore
            if hasMore {
                nextOffsets[pagedCategory] = nextOffset(from: results.paging(for: pagedCategory), offset: offset)
            } else {
                nextOffsets[pagedCategory] = nil
            }
        }
    }

    private func hasMore(
        in results: SpotifySearchResults,
        category: CatalogSearchCategory,
        offset: Int
    ) -> Bool {
        let itemCount = results.itemCount(for: category)
        if let paging = results.paging(for: category) {
            return paging.next != nil || offset + itemCount < paging.total
        }
        return itemCount >= Self.pageSize
    }

    private func nextOffset(from paging: SpotifySearchPaging?, offset: Int) -> Int {
        let fallback = offset + Self.pageSize
        guard let nextURL = paging?.next else { return fallback }
        guard let queryItems = URLComponents(url: nextURL, resolvingAgainstBaseURL: false)?.queryItems else {
            return fallback
        }
        guard let value = queryItems.first(where: { $0.name == "offset" })?.value,
              let parsedOffset = Int(value),
              parsedOffset > offset else {
            return fallback
        }
        return parsedOffset
    }

    private func updatePagingState(from results: SpotifySearchResults, offset: Int) {
        updatePagingState(
            from: results,
            offset: offset,
            hasMoreByCategory: &cachedHasMore,
            nextOffsets: &cachedNextOffsets
        )
    }

    private func resetCache() {
        cachedQuery = nil
        cachedPageCount = 0
        cachedResults = nil
        cachedRawTracks = []
        cachedHasMore = [:]
        cachedNextOffsets = [:]
    }
}
