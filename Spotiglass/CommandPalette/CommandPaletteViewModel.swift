import Foundation

@MainActor
final class CommandPaletteViewModel: ObservableObject {
    @Published var isPresented = false
    @Published var query = ""
    /// Sections in display order. Only sections with non-empty items are emitted.
    @Published private(set) var sections: [(section: CommandPaletteSection, items: [CommandPaletteItem])] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?
    @Published var selectedIndex = 0

    var staticItemsProvider: () -> [CommandPaletteItem] = { [] }
    var searchProvider: (String) async throws -> CommandPaletteSearchResults = { _ in CommandPaletteSearchResults() }
    /// Invoked when the palette wants to restore key-window focus on close.
    var restoreFocus: (() -> Void)?

    private var searchTask: Task<Void, Never>?

    /// Flat list of items across all visible sections, in display order.
    /// Used for arrow-key navigation and Enter execution.
    var visibleItems: [CommandPaletteItem] {
        sections.flatMap(\.items)
    }

    /// Current scope derived from the live query string.
    var currentScope: CommandPaletteScope {
        CommandPaletteScope.parse(query).scope
    }

    /// The portion of the query passed to the search provider (prefix stripped).
    var strippedQuery: String {
        CommandPaletteScope.parse(query).query
    }

    func show() {
        isPresented = true
        query = ""
        selectedIndex = 0
        sections = []
        errorText = nil
        isLoading = false
    }

    func hide() {
        isPresented = false
        query = ""
        selectedIndex = 0
        errorText = nil
        isLoading = false
        searchTask?.cancel()
        searchTask = nil
        restoreFocus?()
    }

    /// Replaces the current query (used by external commands like "filter by artist").
    func applyExternalQuery(_ newQuery: String) {
        query = newQuery
        refresh()
    }

    func refresh() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            guard let self else { return }
            await self.performSearch()
        }
    }

    func moveSelection(delta: Int) {
        let count = visibleItems.count
        guard count > 0 else { return }
        selectedIndex = min(max(0, selectedIndex + delta), count - 1)
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

        case .artists:
            // `@` alone shows nothing; user must type at least one character.
            guard !trimmed.isEmpty else {
                sections = []
                errorText = nil
                isLoading = false
                selectedIndex = 0
                return
            }
            await runRemoteSearch(query: trimmed) { results in
                results.artists
            } sectionKind: {
                .artists
            }

        case .songs:
            guard !trimmed.isEmpty else {
                sections = []
                errorText = nil
                isLoading = false
                selectedIndex = 0
                return
            }
            await runRemoteSearch(query: trimmed) { results in
                results.tracks
            } sectionKind: {
                .tracks
            }
        }
    }

    private func runRemoteSearch(
        query: String,
        pickItems: @escaping (CommandPaletteSearchResults) -> [CommandPaletteItem],
        sectionKind: @escaping () -> CommandPaletteSection
    ) async {
        isLoading = true
        errorText = nil
        do {
            try await Task.sleep(for: .milliseconds(220))
            try Task.checkCancellation()
            let searchResults = try await searchProvider(query)
            try Task.checkCancellation()
            let items = pickItems(searchResults)
            sections = items.isEmpty ? [] : [(sectionKind(), items)]
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
}
