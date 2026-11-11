import AppKit
import SwiftUI
import XCTest
@testable import Spotiglass

/// #499: when the palette's list changed in place (All → Tracks, Artists → Tracks, a search
/// cleared back to the idle list), rows kept the items that were at their places before, while
/// the highlight and Return went by the new list. These tests host the real list, change the model
/// under it the way the palette does, and check which rows are on screen afterwards.
@MainActor
final class CommandPaletteListRefreshTests: XCTestCase {
    private typealias Sections = [(section: CommandPaletteSection, items: [CommandPaletteItem])]

    override func tearDown() {
        ViewBodyTally.onScreen = nil
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    /// ⌘K, `steve lacy`, then ⇥ to Tracks.
    func testSwitchingAllToTracksShowsOnlyTheSongs() {
        assertRows(after: allResults, then: tracksResults, "All → Tracks")
    }

    func testSwitchingArtistsToTracksShowsOnlyTheSongs() {
        assertRows(after: artistResults, then: tracksResults, "Artists → Tracks")
    }

    /// The field cleared after a search, or ⌘K after playing a result: the idle list is shorter
    /// than the results and its sections sit at other places. Its last row is Open Settings.
    func testIdleListAfterResultsShowsNoSongs() {
        assertRows(after: allResults, then: idleList, "results → idle list")
    }

    /// A list that grows (idle list to a fresh search) shows every new row too.
    func testGrowingListStillShowsEveryRow() {
        assertRows(after: idleList, then: allResults, "idle list → search")
    }

    /// The idle list shows commands under "Quick actions": the heading comes from the list's
    /// section, not from the item's own.
    func testRowsKeepTheSectionTheyAreListedUnder() {
        let rows = CommandPaletteListRow.rows(for: idleList)
        XCTAssertEqual(rows.map(\.section), [.recentSearches, .quickActions, .quickActions, .quickActions])
        XCTAssertEqual(rows.map(\.startsSection), [true, true, false, false])
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count, "two rows share a name")
    }

    // MARK: - Replay

    private func assertRows(
        after old: Sections,
        then new: Sections,
        _ step: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let vm = CommandPaletteViewModel()
        vm.show()
        vm.testingReplaceSections(old)
        ViewBodyTally.onScreen = [:]
        // The body view reads `sections` from the model, as the palette does, so the list on
        // screen changes in place instead of being built fresh.
        let controller = ViewTestHost.host(
            CommandPaletteResultsBodyView(viewModel: vm, accessibilityReduceMotion: true)
                .frame(width: 640, height: 800, alignment: .top),
            size: CGSize(width: 640, height: 800)
        )
        // A lazy list puts on screen only the rows it can see. The window stays outside every display.
        controller.view.window?.orderFrontRegardless()
        settle(controller)
        assertOnScreen(old, "before \(step)", file: file, line: line)

        vm.testingReplaceSections(new)
        settle(controller)

        // Return runs `visibleItems[selectedIndex]`; the rows on screen have to be those items.
        XCTAssertEqual(vm.visibleItems.map(\.id), new.flatMap(\.items).map(\.id), file: file, line: line)
        assertOnScreen(new, step, file: file, line: line)
    }

    /// The rows on screen are the top of `sections` (a long list scrolls, and only what it shows
    /// is built) plus "Show all results", pinned under them.
    private func assertOnScreen(_ sections: Sections, _ step: String, file: StaticString, line: UInt) {
        let shown = rowsOnScreen()
        let pinned = sections.filter { $0.section == .showAll }.flatMap(\.items).map(\.id)
        let scrolling = sections.filter { $0.section != .showAll }.flatMap(\.items).map(\.id)
        let expected = Set(pinned + scrolling.prefix(max(0, shown.count - pinned.count)))
        XCTAssertGreaterThan(shown.count, pinned.count, "\(step): no rows on screen", file: file, line: line)
        XCTAssertEqual(
            shown,
            expected,
            "\(step): rows on screen aren't the top of the list (left over: \(shown.subtracting(expected).sorted()))",
            file: file,
            line: line
        )
    }

    private func rowsOnScreen() -> Set<String> {
        let prefix = "CommandPaletteResultRow:"
        return Set((ViewBodyTally.onScreen ?? [:]).keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
    }

    private func settle(_ controller: NSHostingController<AnyView>) {
        for _ in 0 ..< 4 {
            controller.view.layoutSubtreeIfNeeded()
            AppKitTestSupport.pumpRunLoop()
        }
    }

    // MARK: - Fixtures (the lists from the issue)

    private var allResults: Sections {
        [
            (.artists, [item("artist-steve-lacy", "Steve Lacy", .artists)]),
            (.playlists, [
                item("pl-essentials-1", "Steve Lacy Essentials", .playlists),
                item("pl-essentials-2", "Steve Lacy Essentials", .playlists),
            ]),
            (.tracks, [
                item("t-bad-habit", "Bad Habit", .tracks),
                item("t-dark-red", "Dark Red", .tracks),
                item("t-static", "Static", .tracks),
            ]),
            showAll,
        ]
    }

    /// The Artists filter: up to 30 artists, more than the list shows at once.
    private var artistResults: Sections {
        [
            (.artists, [item("artist-steve-lacy", "Steve Lacy", .artists)]
                + (1 ... 13).map { item("artist-\($0)", "Steve Lacy feature \($0)", .artists) }),
            showAll,
        ]
    }

    /// ⇥ to Tracks: one section of songs, longer than the list shows at once.
    private var tracksResults: Sections {
        [
            (.tracks, [
                item("t-bad-habit", "Bad Habit", .tracks),
                item("t-dark-red", "Dark Red", .tracks),
                item("t-static", "Static", .tracks),
                item("t-helmet", "Helmet", .tracks),
                item("t-infrunami", "Infrunami", .tracks),
                item("t-ryd", "Ryd", .tracks),
            ] + (1 ... 14).map { item("t-more-\($0)", "Song \($0)", .tracks) }),
            showAll,
        ]
    }

    /// Every search ends with "Show all results", pinned under the scrolling rows.
    private var showAll: (section: CommandPaletteSection, items: [CommandPaletteItem]) {
        (.showAll, [item("show-all", "Show all results for “steve lacy”", .showAll)])
    }

    private var idleList: Sections {
        [
            (.recentSearches, [item("recent-steve-lacy", "steve lacy", .recentSearches)]),
            (.quickActions, [
                item("qa-liked", "Open Liked Songs", .commands),
                item("qa-queue", "Show Queue", .commands),
                item("qa-settings", "Open Settings", .commands),
            ]),
        ]
    }

    private func item(_ id: String, _ title: String, _ section: CommandPaletteSection) -> CommandPaletteItem {
        CommandPaletteItem(
            id: id,
            title: title,
            subtitle: nil,
            iconSystemName: "music.note",
            section: section,
            keywords: [],
            action: {}
        )
    }
}
