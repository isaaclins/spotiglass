import SwiftUI
import XCTest
@testable import Spotiglass

/// Covers the dedicated catalog Search surface: sidebar routing, pill filtering,
/// the minimum-query-length network gate, and the command-palette handoff.
@MainActor
final class CatalogSearchViewTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeBrowserViewModel() -> PlaylistBrowserViewModel {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: [:]
        )
        return PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
    }

    private func makeCatalogResults() -> SpotifySearchResults {
        SpotifySearchResults(
            tracks: [
                SpotifyTrack(
                    id: "t1",
                    name: "Found Song",
                    artists: ["Found Artist"],
                    albumArtworkURL: nil,
                    durationMilliseconds: 120_000,
                    isExplicit: false,
                    isPlayable: true,
                    linkedFromID: nil,
                    uri: "spotify:track:t1"
                )
            ],
            artists: [
                SpotifyArtist(id: "a1", name: "Found Artist", imageURL: nil, uri: "spotify:artist:a1")
            ],
            albums: [
                SpotifyAlbum(id: "al1", name: "Found Album", artists: ["Found Artist"], imageURL: nil, uri: "spotify:album:al1")
            ],
            playlists: [
                PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "Found Playlist")
            ]
        )
    }

    /// Search view model whose provider records every call it receives.
    private func makeSearchViewModel(
        results: SpotifySearchResults? = nil,
        onCall: (@Sendable () -> Void)? = nil
    ) -> CatalogSearchViewModel {
        let viewModel = CatalogSearchViewModel()
        let payload = results ?? makeCatalogResults()
        viewModel.searchProvider = { _, offset in
            onCall?()
            // Only the first page carries results, so paging terminates.
            return offset == 0
                ? payload
                : SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
        }
        return viewModel
    }

    // MARK: - Sidebar routing

    func testSidebarSearchSelectionRoutesToSearchSurface() async {
        let viewModel = makeBrowserViewModel()

        await viewModel.selectSidebar(.search)

        XCTAssertEqual(viewModel.sidebarSelection, .search)
        XCTAssertEqual(viewModel.detailState, .loaded(.search))
    }

    func testSidebarSearchSelectionShowsSearchBreadcrumb() async {
        let viewModel = makeBrowserViewModel()

        await viewModel.selectSidebar(.search)

        XCTAssertEqual(viewModel.breadcrumbPath.count, 1)
        XCTAssertEqual(viewModel.breadcrumbPath.first?.kind, .search)
        XCTAssertEqual(viewModel.breadcrumbPath.first?.systemImage, "magnifyingglass")
        XCTAssertEqual(
            viewModel.breadcrumbPath.first?.label,
            ViewTestHost.localizedString("browser.search")
        )
    }

    func testSearchSurfaceRendersTheCatalogSearchView() async {
        let viewModel = makeBrowserViewModel()
        await viewModel.selectSidebar(.search)

        let view = CatalogSearchView(
            viewModel: viewModel,
            searchViewModel: viewModel.catalogSearch,
            playbackViewModel: PlaybackSessionViewModel(
                playbackAPI: MockPlaybackAPI(),
                webCommander: MockWebPlaybackCommander(),
                defaults: makeEphemeralDefaults()
            ),
            queueViewModel: QueueViewModel(
                playbackAPI: MockPlaybackAPI(),
                playbackSession: PlaybackSessionViewModel(
                    playbackAPI: MockPlaybackAPI(),
                    webCommander: MockWebPlaybackCommander(),
                    defaults: makeEphemeralDefaults()
                )
            ),
            currentPlaybackURI: nil,
            isPlaying: false,
            hasPlaybackDevice: false
        )
        .environmentObject(PinnedItemsStore(cache: InMemoryPinnedItemsCache()))

        ViewTestHost.host(view, size: CGSize(width: 900, height: 600))
        ViewTestHost.assertFindLocalizedText("search.category.all", in: view)
    }

    // MARK: - Category filtering

    func testCategoryPillNarrowsVisibleSections() async {
        let viewModel = makeSearchViewModel()
        viewModel.query = "found"
        viewModel.queryDidChange()
        await viewModel.waitForSearchCompletion()

        let all = viewModel.visibleResults
        XCTAssertFalse(all.tracks.isEmpty)
        XCTAssertFalse(all.artists.isEmpty)
        XCTAssertFalse(all.albums.isEmpty)
        XCTAssertFalse(all.playlists.isEmpty)

        viewModel.selectCategory(.artists)
        await viewModel.waitForSearchCompletion()

        let artistsOnly = viewModel.visibleResults
        XCTAssertEqual(viewModel.category, .artists)
        XCTAssertFalse(artistsOnly.artists.isEmpty)
        XCTAssertTrue(artistsOnly.tracks.isEmpty)
        XCTAssertTrue(artistsOnly.albums.isEmpty)
        XCTAssertTrue(artistsOnly.playlists.isEmpty)
    }

    func testResultsFilteredToTracksKeepsOnlyTracks() {
        let results = CatalogSearchResults(
            tracks: TrackRowViewModel.numberedTopTracks(makeCatalogResults().tracks),
            artists: makeCatalogResults().artists,
            albums: makeCatalogResults().albums,
            playlists: makeCatalogResults().playlists
        )

        let filtered = results.filtered(to: .tracks)

        XCTAssertEqual(filtered.tracks.count, 1)
        XCTAssertTrue(filtered.artists.isEmpty)
        XCTAssertTrue(filtered.albums.isEmpty)
        XCTAssertTrue(filtered.playlists.isEmpty)
    }

    // MARK: - Minimum length + debounce gate

    func testSingleCharacterQueryDoesNotInvokeSearchProvider() async {
        var callCount = 0
        let viewModel = makeSearchViewModel { callCount += 1 }

        viewModel.query = "a"
        viewModel.queryDidChange()

        XCTAssertEqual(callCount, 0, "A one-character query must not reach /v1/search.")
        XCTAssertFalse(viewModel.meetsMinimumQueryLength)
        guard case .empty = viewModel.state else {
            return XCTFail("Expected the empty prompt state, got \(viewModel.state)")
        }
    }

    func testQueryAtMinimumLengthInvokesSearchProviderOnce() async {
        var callCount = 0
        let viewModel = makeSearchViewModel { callCount += 1 }

        viewModel.query = String(repeating: "a", count: CatalogSearchViewModel.minimumQueryCharacters)
        viewModel.queryDidChange()
        await viewModel.waitForSearchCompletion()

        XCTAssertEqual(callCount, 1)
    }

    func testDebounceCollapsesRapidKeystrokesIntoOneRequest() async {
        var callCount = 0
        let viewModel = makeSearchViewModel { callCount += 1 }

        for text in ["fo", "fou", "foun", "found"] {
            viewModel.query = text
            viewModel.queryDidChange()
        }
        await viewModel.waitForSearchCompletion()

        XCTAssertEqual(callCount, 1, "Rapid keystrokes must collapse into a single search.")
    }

    func testMinimumQueryLengthIsSharedWithTheCommandPalette() {
        XCTAssertEqual(
            CatalogSearchViewModel.minimumQueryCharacters,
            CommandPaletteViewModel.minimumPaletteSearchQueryCharacters
        )
    }

    // MARK: - Palette handoff

    func testPaletteShowAllResultsRowSetsQueryAndScopeOnSearchViewModel() async {
        let browserViewModel = makeBrowserViewModel()
        let searchViewModel = browserViewModel.catalogSearch
        searchViewModel.searchProvider = { _, _ in
            SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
        }

        let palette = CommandPaletteViewModel()
        palette.searchProvider = { _, _ in CommandPaletteSearchResults() }
        // Mirrors PlaylistBrowserCommandPaletteConfiguration's wiring.
        palette.showAllResults = { query, category in
            searchViewModel.applyHandoff(query: query, paletteCategory: category)
            Task { @MainActor in await browserViewModel.selectSidebar(.search) }
        }

        palette.show()
        palette.query = "daft punk"
        palette.searchCategoryFilter = .artists
        palette.refresh()
        await palette.waitForSearchCompletion()

        let showAllRow = try? XCTUnwrap(palette.visibleItems.last)
        XCTAssertEqual(showAllRow?.id, "palette.showAllResults")
        XCTAssertEqual(palette.sections.last?.section, .showAll)

        await showAllRow?.action()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(searchViewModel.query, "daft punk")
        XCTAssertEqual(searchViewModel.category, .artists)
        XCTAssertEqual(browserViewModel.sidebarSelection, .search)
    }

    func testPaletteShowAllResultsRowIsAbsentInCommandScope() async {
        let palette = CommandPaletteViewModel()
        palette.searchProvider = { _, _ in CommandPaletteSearchResults() }
        palette.staticItemsProvider = {
            [
                CommandPaletteItem(
                    id: "cmd",
                    title: "Some Command",
                    subtitle: nil,
                    iconSystemName: "gearshape",
                    section: .commands,
                    keywords: []
                ) {}
            ]
        }
        palette.showAllResults = { _, _ in XCTFail("Command scope must not offer a catalog handoff.") }

        palette.show()
        palette.query = ">some"
        palette.refresh()
        await palette.waitForSearchCompletion()

        XCTAssertFalse(palette.sections.contains { $0.section == .showAll })
    }

    func testPaletteShowAllResultsRowIsAbsentBelowMinimumQueryLength() async {
        let palette = CommandPaletteViewModel()
        palette.searchProvider = { _, _ in CommandPaletteSearchResults() }
        palette.showAllResults = { _, _ in }

        palette.show()
        palette.query = "a"
        palette.refresh()
        await palette.waitForSearchCompletion()

        XCTAssertFalse(palette.sections.contains { $0.section == .showAll })
    }

    func testPaletteCategoryMapsOntoSearchPill() {
        XCTAssertEqual(CatalogSearchCategory.fromPaletteCategory(.tracks), .tracks)
        XCTAssertEqual(CatalogSearchCategory.fromPaletteCategory(.artists), .artists)
        XCTAssertEqual(CatalogSearchCategory.fromPaletteCategory(.all), .all)
        // Palette-only scopes have no catalog equivalent.
        XCTAssertEqual(CatalogSearchCategory.fromPaletteCategory(.thisPlaylist), .all)
        XCTAssertEqual(CatalogSearchCategory.fromPaletteCategory(.myPlaylists), .all)
    }

    // MARK: - Keymap integration

    func testOpenSearchCommandIsRegisteredWithCommandFDefault() throws {
        let spec = try XCTUnwrap(
            CommandPaletteCommandCatalog.editable.first { $0.commandID == CommandPaletteCommandID.openSearch }
        )

        XCTAssertEqual(spec.iconSystemName, "magnifyingglass")
        XCTAssertEqual(spec.defaultWhen, .signedIn)
        XCTAssertEqual(spec.defaultKeystroke, "cmd-f")
        XCTAssertFalse(spec.isDestructive)
        XCTAssertTrue(
            CommandPaletteCommandCatalog.defaultKeymapJSON.contains(CommandPaletteCommandID.openSearch),
            "The command must ship in the default keymap file."
        )
    }

    /// Being in `editable` is what makes the command rebindable in Settings >
    /// Keyboard; this exercises the same store calls that screen makes.
    func testOpenSearchShortcutIsRebindableWithConflictAndReplace() throws {
        let settingsStore = SpotiglassSettingsStore(fileURL: makeCommandPaletteTestsTempSettingsURL())
        let store = CommandPaletteKeymapStore(settingsStore: settingsStore)

        XCTAssertEqual(
            store.primaryShortcut(for: CommandPaletteCommandID.openSearch),
            try CommandShortcut(keystroke: "cmd-f")
        )

        let rebound = try CommandShortcut(keystroke: "shift-cmd-8")
        try store.setBinding(commandID: CommandPaletteCommandID.openSearch, shortcut: rebound, replaceConflicting: false)
        XCTAssertEqual(store.primaryShortcut(for: CommandPaletteCommandID.openSearch), rebound)

        // Conflict detection and the Settings "Replace" flow come for free.
        let taken = try CommandShortcut(keystroke: "cmd-k")
        XCTAssertThrowsError(
            try store.setBinding(commandID: CommandPaletteCommandID.openSearch, shortcut: taken, replaceConflicting: false)
        ) { error in
            XCTAssertEqual(error as? KeymapConflictError, .conflict(existingCommandID: CommandPaletteCommandID.openPalette))
        }
        try store.setBinding(commandID: CommandPaletteCommandID.openSearch, shortcut: taken, replaceConflicting: true)
        XCTAssertEqual(store.primaryShortcut(for: CommandPaletteCommandID.openSearch), taken)
        XCTAssertNil(store.primaryShortcut(for: CommandPaletteCommandID.openPalette))
    }

    /// ⌘K must keep opening the palette out of the box.
    func testCommandKStillOpensThePalette() throws {
        let settingsStore = SpotiglassSettingsStore(fileURL: makeCommandPaletteTestsTempSettingsURL())
        let store = CommandPaletteKeymapStore(settingsStore: settingsStore)

        XCTAssertEqual(
            store.primaryShortcut(for: CommandPaletteCommandID.openPalette),
            try CommandShortcut(keystroke: "cmd-k")
        )
    }

    func testOpenSearchCommandExecutesTheWiredHandler() {
        let manager = CommandPaletteManager(
            keymapStore: CommandPaletteKeymapStore(
                settingsStore: SpotiglassSettingsStore(fileURL: makeCommandPaletteTestsTempSettingsURL())
            )
        )
        var opened = 0
        manager.openSearch = { opened += 1 }

        manager.execute(commandID: CommandPaletteCommandID.openSearch)

        XCTAssertEqual(opened, 1)
    }

    // MARK: - Localization

    /// Guards the regression where a section header rendered as its raw key.
    func testEverySearchStringResolvesToRealCopy() {
        var keys = ["browser.search", "menu.view.search", "palette.section.showAll",
                    "palette.showAllResults.subtitle", "search.field.placeholder",
                    "search.field.clear", "search.state.searching", "search.empty.title",
                    "palette.command.\(CommandPaletteCommandID.openSearch).title",
                    "palette.command.\(CommandPaletteCommandID.openSearch).subtitle"]
        keys += CatalogSearchCategory.allCases.map { "search.category.\($0.rawValue)" }

        for key in keys {
            let resolved = ViewTestHost.localizedString(key)
            XCTAssertNotEqual(resolved, key, "\(key) leaked its raw key into the UI")
            XCTAssertFalse(resolved.isEmpty, "\(key) resolved to an empty string")
        }

        // Section headers reuse the pill labels, so they resolve too.
        for pill in CatalogSearchCategory.allCases {
            XCTAssertFalse(pill.pillLabel.isEmpty)
            XCTAssertNotEqual(pill.pillLabel, "search.category.\(pill.rawValue)")
        }
    }
}
