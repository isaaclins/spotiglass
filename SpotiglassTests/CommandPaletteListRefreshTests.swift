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

    /// In the palette Artists is reached from All, so the list has been All before it.
    func testSwitchingArtistsToTracksShowsOnlyTheSongs() {
        assertRows(through: [allResults, artistResults, tracksResults], "All → Artists → Tracks")
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
        assertRows(through: [old, new], step, file: file, line: line)
    }

    /// Shows each list in turn, as the palette does, and checks the rows and the highlight after
    /// every change and after ↓ ↓.
    private func assertRows(
        through lists: [Sections],
        _ step: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let vm = CommandPaletteViewModel()
        vm.show()
        vm.testingReplaceSections(lists[0])
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
        assertOnScreen(lists[0], "before \(step)", file: file, line: line)

        for (offset, list) in lists.enumerated().dropFirst() {
            let label = "\(step), list \(offset + 1)"
            // A new list starts on its first row, as a fresh search or filter does.
            vm.testingReplaceSections(list)
            vm.selectedIndex = 0
            settle(controller)
            assertOnScreen(list, label, file: file, line: line)
            assertHighlight(vm, label, file: file, line: line)

            // ↓ ↓: the highlight moves to the row Return would run.
            vm.moveSelection(delta: 2)
            settle(controller)
            assertHighlight(vm, "\(label) after ↓ ↓", file: file, line: line)
        }
    }

    /// Return runs `visibleItems[selectedIndex]`; the one highlighted row on screen has to show it.
    private func assertHighlight(_ vm: CommandPaletteViewModel, _ step: String, file: StaticString, line: UInt) {
        XCTAssertEqual(
            highlightedOnScreen(),
            [vm.visibleItems[vm.selectedIndex].id],
            "\(step): the highlighted row isn't the item Return runs",
            file: file,
            line: line
        )
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

    /// The items of the rows on screen, highlighted or not.
    private func rowsOnScreen() -> Set<String> {
        Set(tallied().map { $0.replacingOccurrences(of: CommandPaletteResultRowView.selectedTallySuffix, with: "") })
    }

    /// The items of the highlighted rows on screen.
    private func highlightedOnScreen() -> Set<String> {
        let suffix = CommandPaletteResultRowView.selectedTallySuffix
        return Set(tallied().filter { $0.hasSuffix(suffix) }.map { String($0.dropLast(suffix.count)) })
    }

    private func tallied() -> [String] {
        let prefix = "CommandPaletteResultRow:"
        return (ViewBodyTally.onScreen ?? [:]).keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
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

    /// The Artists filter for `steve lacy`: the one artist.
    private var artistResults: Sections {
        [(.artists, [item("artist-steve-lacy", "Steve Lacy", .artists)]), showAll]
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
