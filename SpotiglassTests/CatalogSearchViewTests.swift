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
        viewModel.searchProvider = { _, offset, _ in
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

    func testCatalogSearchTrackOptionsUseTheSearchRowTargetWithoutMove() throws {
        let track = TrackRowViewModel.numberedTopTracks([makeCatalogResults().tracks[0]])[0]
        let browserViewModel = makeBrowserViewModel()
        browserViewModel.detailState = .loaded(.search)
        let menu = TrackOpsMenuItems(
            targets: [track],
            browserViewModel: browserViewModel,
            sourcePlaylistID: nil
        )

        XCTAssertNoThrow(try menu.inspect().find(text: SpotiglassL10n.string("Add to playlist")))
        XCTAssertThrowsError(
            try menu.inspect().find(text: SpotiglassL10n.string("Move to playlist"))
        )
    }

    func testSearchSurfaceRendersTheCatalogSearchView() async {
        let viewModel = makeBrowserViewModel()
        await viewModel.selectSidebar(.search)
        // The pills only exist once there is a query to filter: with an empty
        // query they were presenting themselves as active filters over nothing
        // (#164).
        viewModel.catalogSearch.query = "daft punk"

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

    func testFocusedCategoryLoadMoreAppendsResultsPastInitialThirty() async {
        let viewModel = CatalogSearchViewModel()
        viewModel.searchProvider = { _, offset, _ in
            let indexes: [Int]
            switch offset {
            case 0, 10, 20:
                indexes = Array((offset + 1)...(offset + 10))
            case 30:
                indexes = [31]
            default:
                indexes = []
            }
            let tracks = indexes.map { index in
                SpotifyTrack(
                    id: "track-\(index)",
                    name: "Track \(index)",
                    artists: ["Artist"],
                    albumArtworkURL: nil,
                    durationMilliseconds: 120_000,
                    isExplicit: false,
                    isPlayable: true,
                    linkedFromID: nil,
                    uri: "spotify:track:track-\(index)"
                )
            }
            return SpotifySearchResults(tracks: tracks, artists: [], albums: [], playlists: [])
        }

        viewModel.query = "many results"
        viewModel.selectCategory(.tracks)
        await viewModel.waitForSearchCompletion()
        XCTAssertEqual(viewModel.visibleResults.tracks.count, 30)

        await viewModel.loadMore()

        XCTAssertEqual(viewModel.visibleResults.tracks.count, 31)
        XCTAssertEqual(viewModel.visibleResults.tracks.last?.id, "track-31")
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

    func testRefreshingSameQueryCallsProviderAgainAndReplacesResults() async {
        let browserViewModel = makeBrowserViewModel()
        await browserViewModel.selectSidebar(.search)
        var callCount = 0
        var cacheModes: [SpotifyRequestCacheMode] = []
        browserViewModel.catalogSearch.searchProvider = { _, offset, cacheMode in
            cacheModes.append(cacheMode)
            guard offset == 0 else {
                return SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
            }
            callCount += 1
            let trackID = callCount == 1 ? "before-refresh" : "after-refresh"
            let track = SpotifyTrack(
                id: trackID,
                name: trackID,
                artists: ["Artist"],
                albumArtworkURL: nil,
                durationMilliseconds: 120_000,
                isExplicit: false,
                isPlayable: true,
                linkedFromID: nil,
                uri: "spotify:track:\(trackID)"
            )
            return SpotifySearchResults(tracks: [track], artists: [], albums: [], playlists: [])
        }
        browserViewModel.catalogSearch.query = "found"
        browserViewModel.catalogSearch.queryDidChange()
        await browserViewModel.catalogSearch.waitForSearchCompletion()

        await browserViewModel.unifiedRefreshMainSurface()
        await browserViewModel.catalogSearch.waitForSearchCompletion()

        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(cacheModes, [.freshOnly, .bypassCache])
        XCTAssertEqual(browserViewModel.catalogSearch.visibleResults.tracks.map(\.id), ["after-refresh"])
    }

    func testSupersededSearchErrorCannotReplaceNewerResults() async {
        let viewModel = CatalogSearchViewModel()
        let oldRequestGate = CatalogSearchErrorGate()
        let oldRequestFinished = expectation(description: "old search finished")
        viewModel.searchProvider = { query, _, _ in
            if query == "old" {
                await oldRequestGate.waitForRelease()
                oldRequestFinished.fulfill()
                throw SpotifyAPIError.rateLimited(retryAfter: 1)
            }
            return self.makeCatalogResults()
        }

        viewModel.query = "old"
        viewModel.queryDidChange()
        await oldRequestGate.waitUntilStarted()

        viewModel.query = "new"
        viewModel.queryDidChange()
        await viewModel.waitForSearchCompletion()
        guard case .loaded = viewModel.state else {
            return XCTFail("The newer query should load before the old request fails")
        }

        await oldRequestGate.release()
        await fulfillment(of: [oldRequestFinished], timeout: 2)

        guard case let .loaded(results) = viewModel.state else {
            return XCTFail("A late error from the old query must not replace the newer results")
        }
        XCTAssertEqual(results.tracks.map(\.id), ["t1"])
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
        searchViewModel.searchProvider = { _, _, _ in
            SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
        }

        let palette = CommandPaletteViewModel()
        palette.searchProvider = { _, _ in CommandPaletteSearchResults() }
        let sidebarSelectionFinished = AsyncSignal()
        // Mirrors PlaylistBrowserCommandPaletteConfiguration's wiring.
        palette.showAllResults = { query, category in
            searchViewModel.applyHandoff(query: query, paletteCategory: category)
            Task { @MainActor in
                await browserViewModel.selectSidebar(.search)
                sidebarSelectionFinished.signal()
            }
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
        let didFinishSidebarSelection = await sidebarSelectionFinished.wait(timeout: .seconds(2))
        XCTAssertTrue(
            didFinishSidebarSelection,
            "Catalog handoff should finish sidebar selection"
        )

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

    /// Pin shipped bound and unpin shipped unbound, so the reversible half of
    /// one pair was keyboard-only in one direction (#168).
    func testPinAndUnpinBothShipWithDefaults() throws {
        let pin = try XCTUnwrap(
            CommandPaletteCommandCatalog.editable.first { $0.commandID == CommandPaletteCommandID.pinSelected }
        )
        let unpin = try XCTUnwrap(
            CommandPaletteCommandCatalog.editable.first { $0.commandID == CommandPaletteCommandID.unpinSelected }
        )

        XCTAssertEqual(pin.defaultKeystroke, "cmd-return")
        XCTAssertEqual(unpin.defaultKeystroke, "shift-cmd-return")
        XCTAssertEqual(pin.defaultWhen, unpin.defaultWhen, "a pair should apply in the same context")

        // The paired chord has to be free, and a real shortcut.
        let chords = CommandPaletteCommandCatalog.editable.compactMap(\.defaultKeystroke)
        XCTAssertEqual(chords.count, Set(chords).count, "no two commands may ship the same default")
        XCTAssertNoThrow(try CommandShortcut(keystroke: try XCTUnwrap(unpin.defaultKeystroke)))
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
                    "search.field.clear", "search.loadMore", "search.loadingMore",
                    "search.state.searching", "search.empty.title",
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

private actor CatalogSearchErrorGate {
    private var hasStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func waitUntilStarted() async {
        if hasStarted {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitForRelease() async {
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if isReleased {
            return
        }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func release() {
        isReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
