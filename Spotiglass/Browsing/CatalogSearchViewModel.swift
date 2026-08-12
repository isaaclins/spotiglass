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
    /// Parameters are the trimmed query and the paging offset.
    var searchProvider: (String, Int) async throws -> SpotifySearchResults = { _, _ in
        SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
    }

    private var searchTask: Task<Void, Never>?
    /// Query the cached page set belongs to; lets pill switches re-filter without refetching.
    private var cachedQuery: String?
    private var cachedPageCount = 0
    private var cachedResults: CatalogSearchResults?

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
        if cachedQuery == trimmedQuery, cachedPageCount >= pageCount(for: newCategory) {
            return
        }
        scheduleSearch()
    }

    func clearQuery() {
        query = ""
        scheduleSearch()
    }

    /// Palette handoff: opens this view pre-populated with the palette's query and scope.
    func applyHandoff(query newQuery: String, paletteCategory: CommandPaletteSearchCategory) {
        query = newQuery
        category = CatalogSearchCategory.fromPaletteCategory(paletteCategory)
        scheduleSearch()
    }

    // MARK: - Search

    private func pageCount(for category: CatalogSearchCategory) -> Int {
        category == .all ? 1 : Self.focusedCategoryPageCount
    }

    /// Debounces, then fetches. Queries below ``minimumQueryCharacters`` never
    /// reach ``searchProvider``.
    func scheduleSearch() {
        searchTask?.cancel()
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
        if cachedQuery == trimmed, let cachedResults, cachedPageCount >= pageCount(for: category) {
            state = cachedResults.isEmpty
                ? .empty(SpotiglassL10n.format("search.empty.noResults", trimmed))
                : .loaded(cachedResults)
            return
        }

        state = .loading
        let pages = pageCount(for: category)
        searchTask = Task { [weak self] in
            guard let self else { return }
            await self.performSearch(query: trimmed, pageCount: pages)
        }
    }

    // periphery:ignore
    internal func waitForSearchCompletion() async {
        await searchTask?.value
    }

    private func performSearch(query trimmed: String, pageCount pages: Int) async {
        do {
            try await Task.sleep(for: .milliseconds(Self.debounceMilliseconds))
            try Task.checkCancellation()

            var merged = CatalogSearchResults()
            var tracks: [SpotifyTrack] = []
            var seenTrackIDs: Set<String> = []
            var seenArtistIDs: Set<String> = []
            var seenAlbumIDs: Set<String> = []
            var seenPlaylistIDs: Set<String> = []

            for page in 0 ..< max(1, pages) {
                let results = try await searchProvider(trimmed, page * Self.pageSize)
                try Task.checkCancellation()
                for track in results.tracks where seenTrackIDs.insert(track.id).inserted {
                    tracks.append(track)
                }
                for artist in results.artists where seenArtistIDs.insert(artist.id).inserted {
                    merged.artists.append(artist)
                }
                for album in results.albums where seenAlbumIDs.insert(album.id).inserted {
                    merged.albums.append(album)
                }
                for playlist in results.playlists where seenPlaylistIDs.insert(playlist.id).inserted {
                    merged.playlists.append(playlist)
                }
                // A short page means the catalog is exhausted for this query.
                if results.tracks.isEmpty, results.artists.isEmpty, results.albums.isEmpty, results.playlists.isEmpty {
                    break
                }
            }
            merged.tracks = TrackRowViewModel.numberedTopTracks(tracks)

            cachedQuery = trimmed
            cachedPageCount = pages
            cachedResults = merged
            state = merged.isEmpty
                ? .empty(SpotiglassL10n.format("search.empty.noResults", trimmed))
                : .loaded(merged)
        } catch is CancellationError {
            return
        } catch {
            resetCache()
            state = .error(PlaylistBrowserViewModel.displayError(for: error))
        }
    }

    private func resetCache() {
        cachedQuery = nil
        cachedPageCount = 0
        cachedResults = nil
    }
}
