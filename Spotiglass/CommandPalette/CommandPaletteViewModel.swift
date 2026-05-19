import Foundation

@MainActor
final class CommandPaletteViewModel: ObservableObject {
    /// Spotify palette search does not call the network until the stripped query has at least this many characters (reduces `/v1/search` traffic).
    static let minimumPaletteSearchQueryCharacters = 2

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
    var searchProvider: (String, CommandPaletteSearchCategory) async throws -> CommandPaletteSearchResults = { _, _ in
        CommandPaletteSearchResults()
    }
    /// Invoked when the palette wants to restore key-window focus on close.
    var restoreFocus: (() -> Void)?

    private var searchTask: Task<Void, Never>?
    /// Skips the next `queryDidChangeFromTextField` refresh after legacy `@` prefix normalization mutates `query` programmatically.
    private var suppressLegacyPrefixQueryRefresh = false
    /// Last songs-scope search that completed successfully; used to skip redundant identical `(query, category)` provider calls.
    private var lastSuccessfulSongSearchKey: (query: String, category: CommandPaletteSearchCategory)?
    /// After Spotify returns HTTP 429, blocks new palette searches until this instant (in addition to client-side GET retries inside `SpotifyAPIClient`).
    private var rateLimitCooldownUntil: Date = .distantPast

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
        lastSuccessfulSongSearchKey = nil
        suppressLegacyPrefixQueryRefresh = false
        rateLimitCooldownUntil = .distantPast
    }

    func hide() {
        isPresented = false
        query = ""
        searchCategoryFilter = .all
        selectedIndex = 0
        errorText = nil
        isLoading = false
        lastSuccessfulSongSearchKey = nil
        suppressLegacyPrefixQueryRefresh = false
        rateLimitCooldownUntil = .distantPast
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
        if parsed.scope == .songs,
           !trimmed.isEmpty,
           trimmed.count >= Self.minimumPaletteSearchQueryCharacters,
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
            lastSuccessfulSongSearchKey = nil
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
                lastSuccessfulSongSearchKey = nil
                sections = []
                errorText = nil
                isLoading = false
                selectedIndex = 0
                return
            }
            guard trimmed.count >= Self.minimumPaletteSearchQueryCharacters else {
                lastSuccessfulSongSearchKey = nil
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
        if Date() < rateLimitCooldownUntil {
            isLoading = false
            return
        }

        let dedupeQuery = query.lowercased()
        if let last = lastSuccessfulSongSearchKey, last.query == dedupeQuery, last.category == category {
            isLoading = false
            return
        }

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
            lastSuccessfulSongSearchKey = (dedupeQuery, category)
            isLoading = false
            selectedIndex = 0
        } catch is CancellationError {
            isLoading = false
        } catch let error as SpotifyAPIError {
            switch error {
            case let .rateLimited(retryAfter):
                let seconds = retryAfter ?? 5
                rateLimitCooldownUntil = Date().addingTimeInterval(seconds)
                lastSuccessfulSongSearchKey = nil
                sections = []
                isLoading = false
                errorText = error.userMessage
                selectedIndex = 0
            default:
                sections = []
                isLoading = false
                errorText = error.userMessage
                selectedIndex = 0
            }
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
