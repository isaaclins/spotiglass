import AppKit
import SwiftUI
import ViewInspector
import XCTest
@testable import Spotiglass

/// The palette as one panel near the top of the window (#472, #462, #469): what it offers before
/// typing, how it fits a short window, and how the selected filter reads.
@MainActor
final class CommandPalettePanelTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    private func command(_ id: String, title: String) -> CommandPaletteItem {
        CommandPaletteItem(id: id, title: title, subtitle: nil, iconSystemName: "command", section: .commands, keywords: []) {}
    }

    private func track(_ index: Int) -> CommandPaletteItem {
        CommandPaletteItem(
            id: "track-\(index)",
            title: "Song \(index)",
            subtitle: "Artist \(index)",
            iconSystemName: "music.note",
            section: .tracks,
            keywords: []
        ) {}
    }

    // MARK: - Before typing

    /// Opening the palette showed a lone field: nothing to pick before typing (#472).
    func testOpeningThePaletteOffersRecentSearchesAndQuickActions() {
        let viewModel = CommandPaletteViewModel()
        viewModel.recentSearches = .inMemory(["daft punk", "midnight city"])
        viewModel.staticItemsProvider = { [unowned self] in
            [
                command(CommandPaletteCommandID.openSettings, title: "Open Settings"),
                command(CommandPaletteCommandID.refreshPlaylists, title: "Refresh"),
                command(CommandPaletteCommandID.togglePlayback, title: "Play/Pause")
            ]
        }

        viewModel.show()

        XCTAssertEqual(viewModel.sections.map(\.section), [.recentSearches, .quickActions])
        XCTAssertEqual(viewModel.sections[0].items.map(\.title), ["daft punk", "midnight city"])
        // Quick actions follow the fixed everyday order and skip commands the host doesn't list.
        XCTAssertEqual(
            viewModel.sections[1].items.map(\.id),
            [CommandPaletteCommandID.togglePlayback, CommandPaletteCommandID.openSettings]
        )
    }

    func testClearingTheQueryBringsTheSuggestionsBack() async {
        let viewModel = CommandPaletteViewModel()
        viewModel.recentSearches = .inMemory(["daft punk"])
        viewModel.show()
        viewModel.query = "da"
        viewModel.refresh()
        await viewModel.waitForSearchCompletion()
        XCTAssertFalse(viewModel.sections.contains { $0.section == .recentSearches })

        viewModel.query = ""
        viewModel.refresh()
        await viewModel.waitForSearchCompletion()
        XCTAssertEqual(viewModel.sections.map(\.section), [.recentSearches])
    }

    func testASearchThatLedToAResultBecomesARecentSearch() async {
        let viewModel = CommandPaletteViewModel()
        let recents = CommandPaletteRecentSearches.inMemory(["older", "Midnight City"])
        viewModel.recentSearches = recents
        viewModel.show()
        viewModel.query = "  midnight city "
        viewModel.testingReplaceSections([(.tracks, [track(1)])])

        await viewModel.executeSelection()

        // Newest first, once, whatever its case or spaces.
        XCTAssertEqual(recents.queries, ["midnight city", "older"])
    }

    /// Queueing a result with ⇧↩ or pinning it with ⌘↩ uses it as much as ↩ does, but only ↩
    /// recorded the search.
    func testQueueingOrPinningAResultRecordsTheSearch() async {
        let viewModel = CommandPaletteViewModel()
        let recents = CommandPaletteRecentSearches.inMemory()
        viewModel.recentSearches = recents
        var queued = 0
        var pinned = 0
        let usable = CommandPaletteItem(
            id: "track-q", title: "Song", subtitle: "Artist", iconSystemName: "music.note",
            section: .tracks, keywords: [], pinAction: { pinned += 1 }, queueAction: { queued += 1 }
        ) {}
        viewModel.show()
        viewModel.query = "midnight city"
        viewModel.testingReplaceSections([(.tracks, [usable])])
        await viewModel.executeSelectionEnqueue()
        viewModel.query = "daft punk"
        viewModel.testingReplaceSections([(.tracks, [usable])])
        await viewModel.executeSelectionPinning()

        XCTAssertEqual(queued, 1)
        XCTAssertEqual(pinned, 1)
        XCTAssertEqual(recents.queries, ["daft punk", "midnight city"])
    }

    /// The quick actions were a snapshot from when the panel opened: Lyrics stayed offered after
    /// the song lost its lyrics, and Play/Pause stayed missing after playback became possible.
    func testQuickActionsFollowWhatTheServiceCanDoWhileThePanelIsOpen() async {
        let manager = CommandPaletteManager()
        manager.isSignedIn = true
        manager.setLyricsToggleAvailability(true)
        manager.setPlaybackToggleAvailability(false)
        manager.viewModel.show()
        func quickActionIDs() -> [String] {
            manager.viewModel.sections.first { $0.section == .quickActions }?.items.map(\.id) ?? []
        }
        XCTAssertTrue(quickActionIDs().contains(CommandPaletteCommandID.toggleLyrics))
        XCTAssertFalse(quickActionIDs().contains(CommandPaletteCommandID.togglePlayback))

        manager.setLyricsToggleAvailability(false)
        manager.setPlaybackToggleAvailability(true)
        await manager.viewModel.waitForSearchCompletion()

        XCTAssertFalse(quickActionIDs().contains(CommandPaletteCommandID.toggleLyrics))
        XCTAssertTrue(quickActionIDs().contains(CommandPaletteCommandID.togglePlayback))

        // One letter still shows the suggestions, so they have to keep up there too.
        manager.viewModel.query = "l"
        manager.viewModel.refresh()
        await manager.viewModel.waitForSearchCompletion()
        manager.setLyricsToggleAvailability(true)
        await manager.viewModel.waitForSearchCompletion()
        XCTAssertTrue(quickActionIDs().contains(CommandPaletteCommandID.toggleLyrics))
    }

    /// One letter is below the search minimum, so the list emptied and the panel collapsed
    /// between the suggestions and the first results. It now keeps the suggestions up, with the
    /// recent searches narrowed to that letter.
    func testOneLetterKeepsTheSuggestionsUp() async {
        let viewModel = CommandPaletteViewModel()
        viewModel.recentSearches = .inMemory(["daft punk", "midnight city", "Disclosure"])
        viewModel.staticItemsProvider = { [unowned self] in
            [command(CommandPaletteCommandID.openSettings, title: "Open Settings")]
        }
        viewModel.show()
        viewModel.query = "d"
        viewModel.refresh()
        await viewModel.waitForSearchCompletion()

        XCTAssertEqual(viewModel.sections.map(\.section), [.recentSearches])
        XCTAssertEqual(viewModel.sections[0].items.map(\.title), ["daft punk", "Disclosure"])

        // The quick actions narrow to the letter as well: "s" matches Open Settings.
        viewModel.query = "s"
        viewModel.refresh()
        await viewModel.waitForSearchCompletion()
        XCTAssertEqual(viewModel.sections.map(\.section), [.quickActions])
        XCTAssertEqual(viewModel.sections[0].items.map(\.id), [CommandPaletteCommandID.openSettings])
    }

    /// The quick actions stayed unfiltered with one letter typed and the highlight stayed where it
    /// was: "x" then ↩ toggled playback, and arrowing to Next Track before typing "d" skipped the
    /// song instead of running the matching recent search.
    func testTypingALetterNeverRunsAnUnrelatedAction() async {
        let viewModel = CommandPaletteViewModel()
        viewModel.recentSearches = .inMemory(["daft punk"])
        var ran: [String] = []
        viewModel.staticItemsProvider = {
            [CommandPaletteCommandID.togglePlayback, CommandPaletteCommandID.nextTrack].map { id in
                CommandPaletteItem(id: id, title: id, subtitle: nil, iconSystemName: "command", section: .commands, keywords: []) {
                    ran.append(id)
                }
            }
        }
        viewModel.show()
        viewModel.selectedIndex = 2 // Next Track, below the recent search and Play/Pause
        viewModel.query = "d"
        viewModel.queryDidChangeFromTextField()
        await viewModel.waitForSearchCompletion()
        XCTAssertEqual(viewModel.visibleItems[viewModel.selectedIndex].title, "daft punk")

        viewModel.query = "x"
        viewModel.queryDidChangeFromTextField()
        await viewModel.waitForSearchCompletion()
        await viewModel.executeSelection()
        XCTAssertEqual(ran, [])
    }

    /// The letter also matched the commands' English keywords, which are never shown: "o" put
    /// Toggle Lyrics ("overlay") above Open Settings, and "s" put Next Track ("skip") first.
    func testALetterMatchesOnlyTheTitlesShown() async {
        let manager = CommandPaletteManager()
        manager.isSignedIn = true
        manager.setPlaybackToggleAvailability(true)
        manager.setLyricsToggleAvailability(true)
        manager.nextTrack = {}
        manager.viewModel.show()
        for (letter, expected) in [("o", CommandPaletteCommandID.openSettings), ("s", CommandPaletteCommandID.openSettings)] {
            manager.viewModel.query = letter
            manager.viewModel.queryDidChangeFromTextField()
            await manager.viewModel.waitForSearchCompletion()
            let quick = manager.viewModel.sections.first { $0.section == .quickActions }?.items ?? []
            XCTAssertEqual(quick.first?.id, expected, "first row for \"\(letter)\"")
            for item in quick {
                let words = item.title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                XCTAssertTrue(words.contains { $0.hasPrefix(letter) }, "\(item.title) listed for \"\(letter)\"")
            }
        }
    }

    /// A Play/Pause or Lyrics availability change rebuilt the suggestions and put the highlight
    /// back on the first row, so ↩ ran something other than the row the user had arrowed to.
    func testRefreshingTheSuggestionsKeepsTheHighlightedRow() async {
        let manager = CommandPaletteManager()
        manager.isSignedIn = true
        manager.setPlaybackToggleAvailability(true)
        manager.viewModel.show()
        let ids = manager.viewModel.visibleItems.map(\.id)
        let settings = try? XCTUnwrap(ids.firstIndex(of: CommandPaletteCommandID.openSettings))
        manager.viewModel.selectedIndex = settings ?? 0
        XCTAssertGreaterThan(manager.viewModel.selectedIndex, 0)

        manager.setLyricsToggleAvailability(true)
        await manager.viewModel.waitForSearchCompletion()

        let items = manager.viewModel.visibleItems
        XCTAssertEqual(items[manager.viewModel.selectedIndex].id, CommandPaletteCommandID.openSettings)
    }

    func testRecentSearchesCanBeCleared() {
        let defaults = makeEphemeralDefaults()
        let recents = CommandPaletteRecentSearches.userDefaults(defaults)
        recents.record("daft punk")
        let viewModel = CommandPaletteViewModel()
        viewModel.recentSearches = recents
        viewModel.show()
        XCTAssertEqual(viewModel.sections.first?.section, .recentSearches)

        viewModel.clearRecentSearches()

        XCTAssertEqual(recents.queries, [])
        XCTAssertNil(defaults.stringArray(forKey: CommandPaletteRecentSearches.defaultsKey))
        XCTAssertFalse(viewModel.sections.contains { $0.section == .recentSearches })
    }

    func testTheClearButtonOnRecentSearchesForgetsThem() throws {
        let recents = CommandPaletteRecentSearches.inMemory(["daft punk"])
        let viewModel = CommandPaletteViewModel()
        viewModel.recentSearches = recents
        viewModel.show()
        // The list is lazy, which ViewInspector can't search, so tap the heading's button itself.
        try CommandPaletteClearRecentsButton(viewModel: viewModel).inspect().find(ViewType.Button.self).tap()

        XCTAssertEqual(recents.queries, [])
        XCTAssertFalse(viewModel.sections.contains { $0.section == .recentSearches })
    }

    func testCommandsAndOneLetterQueriesAreNotRecorded() async {
        let viewModel = CommandPaletteViewModel()
        let recents = CommandPaletteRecentSearches.inMemory()
        viewModel.recentSearches = recents
        viewModel.show()
        viewModel.query = ">settings"
        viewModel.testingReplaceSections([(.commands, [command("x", title: "Open Settings")])])
        await viewModel.executeSelection()
        viewModel.show()
        viewModel.query = "m"
        viewModel.testingReplaceSections([(.tracks, [track(1)])])
        await viewModel.executeSelection()

        XCTAssertEqual(recents.queries, [])
    }

    func testRecentSearchesKeepTheNewestFive() {
        let recents = CommandPaletteRecentSearches.inMemory()
        for query in ["a1", "a2", "a3", "a4", "a5", "a6"] {
            recents.record(query)
        }
        XCTAssertEqual(recents.queries, ["a6", "a5", "a4", "a3", "a2"])
    }

    func testPickingARecentSearchRunsItAndKeepsThePaletteOpen() async {
        let viewModel = CommandPaletteViewModel()
        viewModel.recentSearches = .inMemory(["daft punk"])
        var searched: [String] = []
        viewModel.searchProvider = { query, _ in
            searched.append(query)
            return CommandPaletteSearchResults(tracks: [self.track(1)])
        }
        viewModel.show()

        await viewModel.executeSelection()
        await viewModel.waitForSearchCompletion()

        XCTAssertTrue(viewModel.isPresented)
        XCTAssertEqual(viewModel.query, "daft punk")
        XCTAssertEqual(searched, ["daft punk"])
        XCTAssertEqual(viewModel.sections.first?.section, .tracks)
    }

    func testRecentSearchesInTheDefaultsAreSharedByEveryWindow() {
        let defaults = makeEphemeralDefaults()
        let first = CommandPaletteRecentSearches.userDefaults(defaults)
        let second = CommandPaletteRecentSearches.userDefaults(defaults)
        first.record("daft punk")
        XCTAssertEqual(second.queries, ["daft punk"])
        XCTAssertEqual(defaults.stringArray(forKey: CommandPaletteRecentSearches.defaultsKey), ["daft punk"])
    }

    // MARK: - Short window (#462)

    /// At 900 × 450 the results took a fixed 360 pt and pushed the filters and the key hints out
    /// of the window. The palette now fits the window and the list scrolls inside it.
    func testThePaletteFitsAShortWindowWithManyResults() throws {
        let store = try ViewTestHost.makeSettingsStore()
        let viewModel = CommandPaletteViewModel()
        viewModel.show()
        viewModel.query = "song"
        let showAll = CommandPaletteItem(
            id: "palette.showAllResults", title: "Show all results", subtitle: nil,
            iconSystemName: "magnifyingglass", section: .showAll, keywords: []
        ) {}
        viewModel.testingReplaceSections([(.tracks, (0 ..< 30).map(track)), (.showAll, [showAll])])

        let controller = NSHostingController(rootView: CommandPaletteView(viewModel: viewModel).environmentObject(store))
        // The palette sits below the toolbar (52 pt), so it gets that much less than the window.
        let toolbar: CGFloat = 52
        let windows = [
            CGSize(width: 900, height: 450),
            CGSize(width: 640, height: 400),
            CGSize(width: SpotiglassApp.windowMinWidth, height: SpotiglassApp.windowMinHeight)
        ]
        for window in windows.map({ CGSize(width: $0.width, height: $0.height - toolbar) }) {
            let fitted = controller.sizeThatFits(in: window)
            XCTAssertLessThanOrEqual(fitted.height, window.height, "palette taller than a \(window) window")
        }
    }

    /// In a short window the space above the panel was whatever the panel left over, so the panel
    /// moved down each time the results got shorter (one result sat 63 pt lower than the
    /// suggestions at 900 × 450). Its top edge must not depend on what it shows.
    func testThePanelKeepsItsPlaceWhenTheResultsChange() throws {
        let store = try ViewTestHost.makeSettingsStore()
        let size = CGSize(width: 900, height: 450)
        func panelTop(rows: Int) throws -> Int {
            let viewModel = CommandPaletteViewModel()
            viewModel.show()
            viewModel.query = "song"
            viewModel.testingReplaceSections([(.tracks, (0 ..< rows).map(track))])
            let host = NSHostingView(rootView: CommandPaletteView(viewModel: viewModel)
                .environmentObject(store)
                .background(Color.white)
                .environment(\.colorScheme, .light))
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            AppKitTestSupport.pumpRunLoop(for: 0.2)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return try XCTUnwrap(Self.firstChangedRow(in: XCTUnwrap(bitmap.cgImage)))
        }
        XCTAssertEqual(try panelTop(rows: 1), try panelTop(rows: 30))
    }

    func testTheSpaceAboveThePanelFollowsTheWindowHeight() {
        XCTAssertEqual(CommandPaletteView.topInset(forAvailableHeight: 1_000), SpotiglassDesign.Layout.paletteTopInset)
        XCTAssertEqual(CommandPaletteView.topInset(forAvailableHeight: 500), 50)
        XCTAssertEqual(CommandPaletteView.topInset(forAvailableHeight: 308), SpotiglassDesign.spacingS)
    }

    /// In the shortest window the space around the panel came out of the list first, leaving the
    /// results barely one row. The space gives way first now, so at least two rows show.
    func testTheShortestWindowStillShowsTwoResults() throws {
        let store = try ViewTestHost.makeSettingsStore()
        // The shortest the window really gets is 412 pt (the browser's own minimums hold it above
        // `windowMinHeight`, measured in the app), less the 52 pt toolbar above the palette.
        let size = CGSize(width: SpotiglassApp.windowMinWidth, height: 412 - 52)
        func panelHeight(rows: Int) throws -> Int {
            let viewModel = CommandPaletteViewModel()
            viewModel.show()
            viewModel.query = "song"
            let showAll = CommandPaletteItem(
                id: "palette.showAllResults", title: "Show all results", subtitle: "Open the Search view",
                iconSystemName: "magnifyingglass", section: .showAll, keywords: []
            ) {}
            viewModel.testingReplaceSections([(.tracks, (0 ..< rows).map(track)), (.showAll, [showAll])])
            let host = NSHostingView(rootView: CommandPaletteView(viewModel: viewModel)
                .environmentObject(store)
                .background(Color.white)
                .environment(\.colorScheme, .light))
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            AppKitTestSupport.pumpRunLoop(for: 0.2)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = try XCTUnwrap(bitmap.cgImage)
            let top = try XCTUnwrap(Self.firstChangedRow(in: image))
            return try XCTUnwrap(Self.panelHeight(in: image, from: top))
        }
        let one = try panelHeight(rows: 1)
        let row = try panelHeight(rows: 2) - one
        XCTAssertGreaterThan(row, 20, "a row should add height")
        XCTAssertGreaterThanOrEqual(try panelHeight(rows: 30) - one, row, "fewer than two results fit")
    }

    /// First row, down the middle column, clearly lighter than the dimmed backdrop at the top:
    /// the panel's own edge (its shadow only ever darkens).
    /// Rows from the panel's top edge down to where the dimmed backdrop shows again, read down a
    /// column right of the footer hints and left of "> commands", where no text sits.
    private static func panelHeight(in image: CGImage, from top: Int) -> Int? {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        func brightness(_ row: Int) -> Int {
            let start = (row * width + width * 3 / 4) * 4
            return (0 ..< 3).map { Int(pixels[start + $0]) }.reduce(0, +)
        }
        let backdrop = brightness(1)
        for row in (top + 1) ..< height where brightness(row) <= backdrop + 30 {
            return row - top
        }
        return height - top
    }

    private static func firstChangedRow(in image: CGImage) -> Int? {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        func pixel(_ row: Int) -> [Int] {
            let start = (row * width + width / 2) * 4
            return (0 ..< 4).map { Int(pixels[start + $0]) }
        }
        let reference = pixel(1)[0 ..< 3].reduce(0, +)
        for row in 2 ..< height where pixel(row)[0 ..< 3].reduce(0, +) > reference + 30 {
            return row
        }
        return nil
    }

    /// In the smallest window the footer asked for more width than the panel has once a track
    /// offered ⇧↩ queue and ⌘↩ pin, so "esc close" was cut off at the panel's edge (German, and
    /// English too). It now drops the least needed hints and keeps a margin on the right.
    func testTheFooterFitsThePanelInTheSmallestWindow() throws {
        let store = try ViewTestHost.makeSettingsStore()
        SpotiglassL10n.settingsStore = store
        defer { SpotiglassL10n.settingsStore = nil }
        let panelWidth = SpotiglassApp.windowMinWidth - 2 * SpotiglassDesign.spacingXL
        for language in [AppLanguage.english, .german, .spanish] {
            try store.mutate { $0.appearance.language = language }
            let viewModel = CommandPaletteViewModel()
            viewModel.show()
            viewModel.query = "song"
            let queueable = CommandPaletteItem(
                id: "track-q", title: "Song", subtitle: "Artist", iconSystemName: "music.note",
                section: .tracks, keywords: [], pinAction: {}, queueAction: {}
            ) {}
            viewModel.testingReplaceSections([(.tracks, [queueable])])
            XCTAssertTrue(viewModel.canEnqueueSelectedItem && viewModel.canPinSelectedItem)

            let renderer = ImageRenderer(content: CommandPaletteFooterView(viewModel: viewModel)
                .frame(width: panelWidth)
                .environment(\.colorScheme, .light))
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            let lastInk = try XCTUnwrap(Self.lastInkColumn(in: image))
            XCTAssertLessThanOrEqual(
                CGFloat(lastInk), panelWidth - SpotiglassDesign.spacingM + 1,
                "footer runs into the panel's edge in \(language.rawValue)"
            )
        }
    }

    /// The rightmost pixel column with anything drawn in it.
    private static func lastInkColumn(in image: CGImage) -> Int? {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        for column in stride(from: width - 1, through: 0, by: -1) {
            for row in 0 ..< height where pixels[(row * width + column) * 4 + 3] > 24 {
                return column
            }
        }
        return nil
    }

    /// When the filters don't fit, the row scrolls. ⇥ changed the filter with focus in the field,
    /// so nothing scrolled, and the selected chip could sit clipped past the edge.
    func testTheSelectedFilterScrollsIntoView() throws {
        let viewModel = CommandPaletteViewModel()
        viewModel.show()
        let row = CommandPaletteCategoryPillsRowView(viewModel: viewModel)
            .environment(\.appearsActive, true)
            .environment(\.colorScheme, .light)
            .frame(width: 150)
            .background(Color.white)
        let controller = ViewTestHost.host(row, size: CGSize(width: 150, height: 60))
        let last = try XCTUnwrap(viewModel.availableSearchCategories.last)
        XCTAssertNotEqual(last, viewModel.searchCategoryFilter)

        viewModel.selectCategory(last)
        AppKitTestSupport.pumpRunLoop(for: 0.4)

        let host = controller.view
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(Self.accentPixelCount(in: try XCTUnwrap(bitmap.cgImage)), 40, "selected chip is out of view")
    }

    /// Pixels that are clearly the blue accent fill.
    private static func accentPixelCount(in image: CGImage) -> Int {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 0, to: pixels.count, by: 4).filter { index in
            Int(pixels[index + 2]) - Int(pixels[index]) > 80
        }.count
    }

    /// The results list built every row at once. "Here" and "My Playlists" are uncapped, so a
    /// long playlist built thousands of rows (each starting an artwork load) on every keystroke.
    /// Only the rows on screen may be built.
    func testALongResultListBuildsOnlyTheRowsOnScreen() throws {
        let viewModel = CommandPaletteViewModel()
        viewModel.show()
        viewModel.query = "the"
        let rows = (0 ..< 6_000).map(track)
        viewModel.testingReplaceSections([(.tracks, rows)])
        let list = CommandPaletteSectionedListView(
            viewModel: viewModel, sections: viewModel.sections, accessibilityReduceMotion: true
        )
        let start = Date()
        _ = ViewTestHost.host(list, size: CGSize(width: 700, height: 400))
        let elapsed = Date().timeIntervalSince(start)
        print("palette list of 6000 rows laid out in \(elapsed) s")
        XCTAssertLessThan(elapsed, 1.0, "the list builds rows that aren't on screen")
    }

    // MARK: - Selected filter (#469)

    /// The selected chip drew a fixed white label on the accent, and the accent turns white while
    /// the window is not the active one: a white blob with no label.
    func testTheSelectedFilterKeepsItsLabelInAnInactiveWindow() throws {
        for scheme in [ColorScheme.dark, .light] {
            for active in [true, false] {
                let viewModel = CommandPaletteViewModel()
                viewModel.show()
                let chip = CommandPaletteCategoryPillView(category: .all, viewModel: viewModel)
                    .environment(\.appearsActive, active)
                    .environment(\.colorScheme, scheme)
                    .padding(SpotiglassDesign.spacingXS)
                let renderer = ImageRenderer(content: chip)
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.cgImage)
                let contrast = try XCTUnwrap(Self.labelContrast(in: image))
                XCTAssertGreaterThan(contrast, 0.35, "label unreadable on the selected chip (\(scheme), active \(active))")
            }
        }
    }

    /// The spread between the fill (the most common opaque luminance) and the pixels furthest from it.
    private static func labelContrast(in image: CGImage) -> Double? {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var buckets = [Int](repeating: 0, count: 21)
        var lumas: [Double] = []
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 250 {
            let luma = (0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])) / 255
            lumas.append(luma)
            buckets[Int((luma * 20).rounded())] += 1
        }
        guard let fillBucket = buckets.indices.max(by: { buckets[$0] < buckets[$1] }) else { return nil }
        let fill = Double(fillBucket) / 20
        // Ignore the stray few per cent of anti-aliasing: the label must cover real pixels.
        let far = lumas.map { abs($0 - fill) }.sorted(by: >)
        guard !far.isEmpty else { return nil }
        return far[min(far.count - 1, far.count / 50)]
    }
}
