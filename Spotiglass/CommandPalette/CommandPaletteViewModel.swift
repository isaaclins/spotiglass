import Foundation

@MainActor
final class CommandPaletteViewModel: ObservableObject {
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

    var staticItemsProvider: () -> [CommandPaletteItem] = { [] }
    var searchProvider: (String, CommandPaletteSearchCategory) async throws -> CommandPaletteSearchResults = { _, _ in
        CommandPaletteSearchResults()
    }
    /// Invoked when the palette wants to restore key-window focus on close.
    var restoreFocus: (() -> Void)?

    private var searchTask: Task<Void, Never>?

    /// Flat list of items across all visible sections, in display order.
    /// Used for arrow-key navigation and Enter execution.
    var visibleItems: [CommandPaletteItem] {
        sections.flatMap(\.items)
    }

    /// Test hook for `@testable import`; replaces visible search rows without running a query.
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
    }

    func hide() {
        isPresented = false
        query = ""
        searchCategoryFilter = .all
        selectedIndex = 0
        errorText = nil
        isLoading = false
        searchTask?.cancel()
        searchTask = nil
        restoreFocus?()
    }

    /// Replaces the current query (used by external commands like "filter by artist").
    func applyExternalQuery(_ newQuery: String) {
        searchCategoryFilter = .all
        query = newQuery
        refresh()
    }

    func refresh() {
        normalizeLegacyArtistPrefix()
        let parsed = CommandPaletteScope.parse(query)
        let trimmed = parsed.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if parsed.scope == .songs,
           !trimmed.isEmpty,
           searchCategoryFilter != .thisPlaylist {
            isLoading = true
            errorText = nil
        }
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            guard let self else { return }
            await self.performSearch()
        }
    }

    /// Legacy `@` prefix maps to the Artists category and is stripped from the query.
    private func normalizeLegacyArtistPrefix() {
        guard !query.hasPrefix(">"), query.hasPrefix("@") else { return }
        searchCategoryFilter = .artists
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
        searchCategoryFilter = forward ? searchCategoryFilter.next(in: ordered) : searchCategoryFilter.previous(in: ordered)
        refresh()
    }

    func executeSelection() async {
        let items = visibleItems
        guard items.indices.contains(selectedIndex) else { return }
        let item = items[selectedIndex]
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
                sections = []
                errorText = nil
                isLoading = false
                selectedIndex = 0
                return
            }
            await runSongScopeSearch(query: trimmed, category: searchCategoryFilter)
        }
    }

    /// Spotify search with optional section filter from the footer control.
    private func runSongScopeSearch(query: String, category: CommandPaletteSearchCategory) async {
        isLoading = true
        errorText = nil
        do {
            if category != .thisPlaylist {
                try await Task.sleep(for: .milliseconds(340))
                try Task.checkCancellation()
            }
            let searchResults = try await searchProvider(query, category)
            try Task.checkCancellation()
            sections = Self.sections(from: searchResults, category: category)
            isLoading = false
            selectedIndex = 0
        } catch is CancellationError {
            isLoading = false
        } catch {
            sections = []
            isLoading = false
            errorText = error.localizedDescription
            selectedIndex = 0
        }
    }

    private static func sections(
        from searchResults: CommandPaletteSearchResults,
        category: CommandPaletteSearchCategory
    ) -> [(section: CommandPaletteSection, items: [CommandPaletteItem])] {
        switch category {
        case .all:
            var built: [(section: CommandPaletteSection, items: [CommandPaletteItem])] = []
            let mergedPlaylists = searchResults.mergedPlaylistsForAllCategory()
            if !mergedPlaylists.isEmpty {
                built.append((.playlists, mergedPlaylists))
            }
            if !searchResults.inPlaylistMatches.isEmpty {
                built.append((.thisPlaylist, searchResults.inPlaylistMatches))
            }
            if !searchResults.tracks.isEmpty {
                built.append((.tracks, searchResults.tracks))
            }
            if !searchResults.artists.isEmpty {
                built.append((.artists, searchResults.artists))
            }
            if !searchResults.albums.isEmpty {
                built.append((.albums, searchResults.albums))
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
