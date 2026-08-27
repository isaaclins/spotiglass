import Foundation

@MainActor
final class CommandPaletteViewModel: ObservableObject {
    /// Spotify palette search does not call the network until the stripped query has at least this many characters (reduces `/v1/search` traffic).
    static let minimumPaletteSearchQueryCharacters = 2

    /// Max rows shown per primary section (tracks, this-playlist) in the unified **All** view.
    static let allSectionCap = 6
    /// Max rows shown per secondary section (artists, albums, playlists) in the unified **All** view.
    static let allSecondarySectionCap = 4

    @Published var isPresented = false
    @Published var query = ""
    /// Filters Spotify search sections when not in command (`>`) scope.
    @Published var searchCategoryFilter: CommandPaletteSearchCategory = .all
    /// Footer segments (Tab order); host updates when a playlist is open for in-playlist search.
    @Published private(set) var availableSearchCategories: [CommandPaletteSearchCategory] =
        CommandPaletteSearchCategory.footerOrder(includeThisPlaylist: false)
    /// Sections in display order. Only sections with non-empty items are emitted.
    @Published private(set) var sections: [(section: CommandPaletteSection, items: [CommandPaletteItem])] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?
    @Published var selectedIndex = 0
    /// Bulk playlist-track prefetch progress, mirrored from the host browser
    /// view-model. Non-`nil` while a run is in flight (or briefly after it
    /// finishes so the palette can render a "Loaded N playlists" header).
    @Published var prefetchProgress: PrefetchAllPlaylistsProgress?
    /// Wired by `CommandPaletteManager`; invokes the same toggle the keymap uses,
    /// so the in-palette "cancel" chip cancels the run without coupling the view
    /// to the host browser view-model.
    var cancelPrefetchAllPlaylists: (() -> Void)?

    var staticItemsProvider: () -> [CommandPaletteItem] = { [] }
    /// Network-backed Spotify catalog search. Always invoked for the full multi-type
    /// result set (the category is a display-time filter, not a fetch parameter).
    var searchProvider: (String, CommandPaletteSearchCategory) async throws -> CommandPaletteSearchResults = { _, _ in
        CommandPaletteSearchResults()
    }
    /// Synchronous, in-memory matches (open-playlist tracks + library playlists) rendered
    /// instantly on every keystroke so the list never blanks while the catalog fetch is in flight.
    var localResultsProvider: (String) -> CommandPaletteSearchResults = { _ in CommandPaletteSearchResults() }
    /// Invoked when the palette wants to restore key-window focus on close.
    var restoreFocus: (() -> Void)?
    /// Hands the current catalog query off to the dedicated Search view. When
    /// `nil` (no browser host wired) the "Show all results" row is omitted.
    var showAllResults: ((String, CommandPaletteSearchCategory) -> Void)?

    private var searchTask: Task<Void, Never>?
    /// Skips the next `queryDidChangeFromTextField` refresh after legacy `@` prefix normalization mutates `query` programmatically.
    private var suppressLegacyPrefixQueryRefresh = false
    /// Lowercased query of the last songs-scope search whose catalog fetch completed; skips redundant identical network calls.
    private var lastSuccessfulSongSearchQuery: String?
    /// Best-known result set (instant local matches, upgraded to local+catalog once the network returns)
    /// for ``cachedResultsQuery``. Lets the footer category pills re-filter instantly without re-querying.
    private var cachedResults: CommandPaletteSearchResults?
    /// Trimmed query that ``cachedResults`` corresponds to.
    private var cachedResultsQuery: String?
    /// After Spotify returns HTTP 429, blocks new palette searches until this instant (in addition to client-side GET retries inside `SpotifyAPIClient`).
    private var rateLimitCooldownUntil: Date = .distantPast

    deinit {
        searchTask?.cancel()
    }

    /// Flat list of items across all visible sections, in display order.
    /// Used for arrow-key navigation and Enter execution.
    var visibleItems: [CommandPaletteItem] {
        sections.flatMap(\.items)
    }

    /// Test hook for `@testable import`; replaces visible search rows without running a query (tests only; not indexed by Periphery scan).
    // periphery:ignore
    internal func testingReplaceSections(_ newSections: [(section: CommandPaletteSection, items: [CommandPaletteItem])]) {
        sections = newSections
        if visibleItems.isEmpty {
            selectedIndex = 0
        } else {
            selectedIndex = min(selectedIndex, visibleItems.count - 1)
        }
    }

    /// Current scope derived from the live query string.
    var currentScope: CommandPaletteScope {
        CommandPaletteScope.parse(query).scope
    }

    /// The portion of the query passed to the search provider (prefix stripped).
    var strippedQuery: String {
        CommandPaletteScope.parse(query).query
    }

    /// Call from the host when the browser opens/closes a playlist detail so the footer and active filter stay valid.
    func setAvailableSearchCategories(_ categories: [CommandPaletteSearchCategory], refreshIfFilterInvalidated: Bool = true) {
        availableSearchCategories = categories
        if !categories.contains(searchCategoryFilter) {
            searchCategoryFilter = categories.first ?? .all
            if refreshIfFilterInvalidated, isPresented {
                refresh()
            }
        }
    }

    func show() {
        isPresented = true
        query = ""
        searchCategoryFilter = availableSearchCategories.first ?? .all
        selectedIndex = 0
        sections = []
        errorText = nil
        isLoading = false
        lastSuccessfulSongSearchQuery = nil
        cachedResults = nil
        cachedResultsQuery = nil
        suppressLegacyPrefixQueryRefresh = false
        rateLimitCooldownUntil = .distantPast
        prefetchProgress = nil
    }

    func hide() {
        isPresented = false
        query = ""
        searchCategoryFilter = .all
        selectedIndex = 0
        sections = []
        errorText = nil
        isLoading = false
        lastSuccessfulSongSearchQuery = nil
        cachedResults = nil
        cachedResultsQuery = nil
        suppressLegacyPrefixQueryRefresh = false
        rateLimitCooldownUntil = .distantPast
        prefetchProgress = nil
        searchTask?.cancel()
        searchTask = nil
        let restoreFocus = restoreFocus
        self.restoreFocus = nil
        restoreFocus?()
    }

    /// Replaces the current query (used by external commands like "filter by artist").
    func applyExternalQuery(_ newQuery: String) {
        searchCategoryFilter = .all
        query = newQuery
        refresh()
    }

    /// Call from the search field’s `.onChange` so legacy `@` stripping does not schedule a duplicate refresh.
    func queryDidChangeFromTextField() {
        if suppressLegacyPrefixQueryRefresh {
            suppressLegacyPrefixQueryRefresh = false
            return
        }
        refresh()
    }

    func refresh() {
        normalizeLegacyArtistPrefix()
        let parsed = CommandPaletteScope.parse(query)
        let trimmed = parsed.query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        if parsed.scope == .songs,
           !trimmed.isEmpty,
           trimmed.count >= Self.minimumPaletteSearchQueryCharacters {
            // Local-first: paint in-memory matches immediately so the list never goes
            // blank while the debounced catalog fetch is in flight.
            renderInstantLocalResults(trimmed: trimmed)
            isLoading = true
            errorText = nil
        }
        searchTask = Task { [weak self] in
            guard let self else { return }
            await self.performSearch()
        }
    }

    // periphery:ignore
    internal func waitForSearchCompletion() async {
        await searchTask?.value
    }

    /// Re-filters the cached result set for `category` without hitting the network when the
    /// current query's results are already loaded; otherwise falls back to a fresh search.
    /// This is what makes the footer pills (and Tab) switch instantly instead of re-querying.
    func selectCategory(_ category: CommandPaletteSearchCategory) {
        guard CommandPaletteScope.parse(query).scope != .commands else { return }
        searchCategoryFilter = category
        let trimmed = strippedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           trimmed.count >= Self.minimumPaletteSearchQueryCharacters,
           cachedResultsQuery == trimmed,
           cachedResults != nil {
            renderSectionsFromCache(trimmed: trimmed)
        } else {
            refresh()
        }
    }

    /// Legacy `@` prefix maps to the Artists category and is stripped from the query.
    private func normalizeLegacyArtistPrefix() {
        guard !query.hasPrefix(">"), query.hasPrefix("@") else { return }
        searchCategoryFilter = .artists
        suppressLegacyPrefixQueryRefresh = true
        query = String(query.dropFirst())
    }

    func moveSelection(delta: Int) {
        let count = visibleItems.count
        guard count > 0 else { return }
        selectedIndex = min(max(0, selectedIndex + delta), count - 1)
    }

    /// Cycles the Spotify search category (footer segments). No-op in command scope.
    func cycleSearchCategory(forward: Bool) {
        guard CommandPaletteScope.parse(query).scope != .commands else { return }
        let ordered = availableSearchCategories
        let next = forward ? searchCategoryFilter.next(in: ordered) : searchCategoryFilter.previous(in: ordered)
        selectCategory(next)
    }

    func executeSelection() async {
        let items = visibleItems
        guard items.indices.contains(selectedIndex) else { return }
        let item = items[selectedIndex]
        guard item.canExecute?() ?? true else { return }
        await item.action()
        if !item.keepsPaletteOpen {
            hide()
        }
    }

    /// Runs the highlighted palette item's ``pinAction`` (if any) without
    /// dismissing the palette. No-op when the highlighted item is not
    /// pinnable, so spamming ⌘↩ on commands or empty results stays inert.
    func executeSelectionPinning() async {
        let items = visibleItems
        guard items.indices.contains(selectedIndex) else { return }
        let item = items[selectedIndex]
        guard let pinAction = item.pinAction else { return }
        pinAction()
    }

    /// Symmetric to ``executeSelectionPinning()`` but invokes ``unpinAction``.
    /// Used by the rebindable `palette.unpin` command.
    func executeSelectionUnpinning() async {
        let items = visibleItems
        guard items.indices.contains(selectedIndex) else { return }
        let item = items[selectedIndex]
        guard let unpinAction = item.unpinAction else { return }
        unpinAction()
    }

    /// Runs the highlighted palette item's ``queueAction`` (if any) without
    /// dismissing the palette. No-op when the row is not a track, so spamming
    /// ⇧↩ on commands / artists / playlists / albums stays inert.
    func executeSelectionEnqueue() async {
        let items = visibleItems
        guard items.indices.contains(selectedIndex) else { return }
        let item = items[selectedIndex]
        guard let queueAction = item.queueAction else { return }
        await queueAction()
    }

    /// True when the currently-highlighted item exposes a `pinAction`. Used
    /// by `CommandPaletteView` to surface the `⌘↩ pin` footer hint.
    var canPinSelectedItem: Bool {
        let items = visibleItems
        guard items.indices.contains(selectedIndex) else { return false }
        return items[selectedIndex].pinAction != nil
    }

    /// True when the currently-highlighted item exposes a `queueAction`. Drives
    /// the conditional `⇧↩ queue` footer hint in `CommandPaletteView`.
    var canEnqueueSelectedItem: Bool {
        let items = visibleItems
        guard items.indices.contains(selectedIndex) else { return false }
        return items[selectedIndex].queueAction != nil
    }

    private func performSearch() async {
        let parsed = CommandPaletteScope.parse(query)
        let scope = parsed.scope
        let trimmed = parsed.query.trimmingCharacters(in: .whitespacesAndNewlines)

        switch scope {
        case .commands:
            resetSongSearchCache()
            // `>` alone lists every static command. Any query filters by score.
            let staticItems = staticItemsProvider()
            let filtered: [CommandPaletteItem]
            if trimmed.isEmpty {
                filtered = staticItems
            } else {
                filtered = staticItems
                    .map { (item: $0, score: $0.score(for: trimmed)) }
                    .filter { $0.score < 100 }
                    .sorted { lhs, rhs in
                        if lhs.score != rhs.score { return lhs.score < rhs.score }
                        return lhs.item.title < rhs.item.title
                    }
                    .map(\.item)
            }
            errorText = nil
            isLoading = false
            sections = filtered.isEmpty ? [] : [(.commands, filtered)]
            selectedIndex = 0

        case .songs:
            guard !trimmed.isEmpty else {
                resetSongSearchCache()
                sections = []
                errorText = nil
                isLoading = false
                selectedIndex = 0
                return
            }
            guard trimmed.count >= Self.minimumPaletteSearchQueryCharacters else {
                resetSongSearchCache()
                sections = []
                errorText = nil
                isLoading = false
                selectedIndex = 0
                return
            }
            await runSongScopeSearch(query: trimmed)
        }
    }

    /// Clears the cached result set and network-dedupe marker so the next songs search refetches.
    private func resetSongSearchCache() {
        lastSuccessfulSongSearchQuery = nil
        cachedResults = nil
        cachedResultsQuery = nil
    }

    /// Fetches the full Spotify catalog result set (debounced) and merges it over the
    /// instant local matches already on screen. The category is applied at render time,
    /// not requested from the network, so switching pills never triggers another fetch.
    private func runSongScopeSearch(query: String) async {
        if Date() < rateLimitCooldownUntil {
            isLoading = false
            return
        }

        let dedupeQuery = query.lowercased()
        if lastSuccessfulSongSearchQuery == dedupeQuery, cachedResultsQuery == query, cachedResults != nil {
            renderSectionsFromCache(trimmed: query)
            isLoading = false
            return
        }

        isLoading = true
        errorText = nil
        do {
            try await Task.sleep(for: .milliseconds(200))
            try Task.checkCancellation()
            // Always fetch the full multi-type result set; the category is a display filter.
            let providerStart = Date()
            let searchResults = try await searchProvider(query, .all)
            SpotiglassLog.info(.api, "palette search '\(query)' provider \(Int(Date().timeIntervalSince(providerStart) * 1000))ms")
            try Task.checkCancellation()
            cachedResults = searchResults
            cachedResultsQuery = query
            lastSuccessfulSongSearchQuery = dedupeQuery
            renderSectionsFromCache(trimmed: query)
            isLoading = false
        } catch is CancellationError {
            isLoading = false
        } catch let error as SpotifyAPIError {
            switch error {
            case let .rateLimited(retryAfter):
                let seconds = retryAfter ?? 5
                rateLimitCooldownUntil = Date().addingTimeInterval(seconds)
                lastSuccessfulSongSearchQuery = nil
                // Keep any instant local matches visible; only the catalog half failed.
                isLoading = false
                errorText = error.userMessage
            default:
                lastSuccessfulSongSearchQuery = nil
                isLoading = false
                errorText = error.userMessage
            }
        } catch {
            lastSuccessfulSongSearchQuery = nil
            isLoading = false
            errorText = error.localizedDescription
        }
    }

    /// Paints in-memory matches (open-playlist tracks + library playlists) immediately.
    /// On a same-query re-render it refreshes only the local portions so already-fetched
    /// catalog hits are preserved; on a new query it resets the cache to the local set.
    private func renderInstantLocalResults(trimmed: String) {
        let local = localResultsProvider(trimmed)
        if cachedResultsQuery == trimmed, var existing = cachedResults {
            existing.inPlaylistMatches = local.inPlaylistMatches
            existing.myPlaylists = local.myPlaylists
            cachedResults = existing
        } else {
            cachedResults = local
            cachedResultsQuery = trimmed
        }
        renderSectionsFromCache(trimmed: trimmed)
    }

    /// Rebuilds the visible sections from ``cachedResults`` for the active category.
    private func renderSectionsFromCache(trimmed: String) {
        let results = cachedResults ?? CommandPaletteSearchResults()
        var built = Self.sections(from: results, category: searchCategoryFilter, query: trimmed)
        if let row = showAllResultsItem(trimmed: trimmed) {
            built.append((.showAll, [row]))
        }
        sections = built
        selectedIndex = 0
    }

    /// Trailing "Show all results for <query>" row that dismisses the palette and
    /// opens the browsable Search view with the same query and scope. Command
    /// scope (`>` prefix) never gets one: those results are not catalog searches.
    private func showAllResultsItem(trimmed: String) -> CommandPaletteItem? {
        guard let showAllResults else { return nil }
        guard CommandPaletteScope.parse(query).scope == .songs else { return nil }
        guard trimmed.count >= Self.minimumPaletteSearchQueryCharacters else { return nil }
        let category = searchCategoryFilter
        return CommandPaletteItem(
            id: "palette.showAllResults",
            title: SpotiglassL10n.format("palette.showAllResults", trimmed),
            subtitle: SpotiglassL10n.string("palette.showAllResults.subtitle"),
            iconSystemName: "magnifyingglass",
            section: .showAll,
            keywords: [trimmed],
            action: { showAllResults(trimmed, category) }
        )
    }

    /// Section relevance for `.all` ordering. Prefers matches on an item's own name (title)
    /// and demotes matches that only hit secondary fields — a song matched by its artist, a
    /// playlist matched by its owner — so typing an artist's name floats the Artist above that
    /// artist's songs (and a song title still floats Tracks to the top).
    private static func sectionRelevance(_ items: [CommandPaletteItem], for query: String) -> Int {
        let needle = query.lowercased()
        var best = 100
        for item in items {
            let title = item.title.lowercased()
            let score: Int
            if title == needle {
                score = 0
            } else if title.hasPrefix(needle) {
                score = 1
            } else if title.contains(needle) {
                score = 2
            } else {
                // Matches only via subtitle/keywords: rank below any title match.
                let broad = item.score(for: query)
                score = broad >= 100 ? 100 : broad + 10
            }
            best = min(best, score)
            if best == 0 { break }
        }
        return best
    }

    private static func sections(
        from searchResults: CommandPaletteSearchResults,
        category: CommandPaletteSearchCategory,
        query: String
    ) -> [(section: CommandPaletteSection, items: [CommandPaletteItem])] {
        switch category {
        case .all:
            // The unified view is a balanced, scannable *preview* of each type — the dedicated
            // pills show the full list. Caps keep one type (usually name-matched playlists) from
            // flooding the viewport and burying the song you actually searched for.
            var built: [(section: CommandPaletteSection, items: [CommandPaletteItem])] = []
            if !searchResults.inPlaylistMatches.isEmpty {
                built.append((.thisPlaylist, Array(searchResults.inPlaylistMatches.prefix(Self.allSectionCap))))
            }
            if !searchResults.tracks.isEmpty {
                built.append((.tracks, Array(searchResults.tracks.prefix(Self.allSectionCap))))
            }
            if !searchResults.artists.isEmpty {
                built.append((.artists, Array(searchResults.artists.prefix(Self.allSecondarySectionCap))))
            }
            if !searchResults.albums.isEmpty {
                built.append((.albums, Array(searchResults.albums.prefix(Self.allSecondarySectionCap))))
            }
            let mergedPlaylists = searchResults.mergedPlaylistsForAllCategory()
            if !mergedPlaylists.isEmpty {
                built.append((.playlists, Array(mergedPlaylists.prefix(Self.allSecondarySectionCap))))
            }
            // Smart ordering: float the section whose closest hit best matches the query
            // (typing an artist name surfaces Artists first; a song title surfaces Tracks).
            // Ties fall back to the canonical order — songs/artists ahead of playlists, since a
            // name-matched playlist is rarely what you meant when you typed a track or artist.
            let canonicalOrder: [CommandPaletteSection] = [.thisPlaylist, .tracks, .artists, .albums, .playlists]
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                built.sort { lhs, rhs in
                    let lScore = sectionRelevance(lhs.items, for: trimmed)
                    let rScore = sectionRelevance(rhs.items, for: trimmed)
                    if lScore != rScore { return lScore < rScore }
                    let lRank = canonicalOrder.firstIndex(of: lhs.section) ?? canonicalOrder.count
                    let rRank = canonicalOrder.firstIndex(of: rhs.section) ?? canonicalOrder.count
                    return lRank < rRank
                }
            }
            return built
        case .thisPlaylist:
            return searchResults.inPlaylistMatches.isEmpty ? [] : [(.thisPlaylist, searchResults.inPlaylistMatches)]
        case .myPlaylists:
            return searchResults.myPlaylists.isEmpty ? [] : [(.myPlaylists, searchResults.myPlaylists)]
        case .tracks:
            return searchResults.tracks.isEmpty ? [] : [(.tracks, searchResults.tracks)]
        case .artists:
            return searchResults.artists.isEmpty ? [] : [(.artists, searchResults.artists)]
        }
    }
}
