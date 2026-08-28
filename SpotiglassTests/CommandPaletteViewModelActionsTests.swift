import XCTest
@testable import Spotiglass

@MainActor
final class CommandPaletteViewModelActionsTests: XCTestCase {
    func testApplyExternalQueryResetsCategoryAndRefreshes() async {
        let viewModel = CommandPaletteViewModel()
        viewModel.searchCategoryFilter = .tracks
        viewModel.applyExternalQuery("artist:foo")
        XCTAssertEqual(viewModel.query, "artist:foo")
        XCTAssertEqual(viewModel.searchCategoryFilter, .all)
    }

    func testQueryDidChangeFromTextFieldSkipsWhenLegacyPrefixNormalized() async {
        let viewModel = CommandPaletteViewModel()
        var callCount = 0
        viewModel.searchProvider = { _, _ in
            callCount += 1
            return CommandPaletteSearchResults()
        }
        viewModel.show()
        viewModel.query = "@artist"
        viewModel.refresh()
        await viewModel.waitForSearchCompletion()
        let afterLegacy = callCount
        viewModel.queryDidChangeFromTextField()
        await viewModel.waitForSearchCompletion()
        XCTAssertEqual(callCount, afterLegacy, "Suppress flag should skip duplicate refresh after @ normalization")
    }

    func testMoveSelectionClampsAndNoOpsOnEmpty() {
        let viewModel = CommandPaletteViewModel()
        viewModel.moveSelection(delta: 1)
        XCTAssertEqual(viewModel.selectedIndex, 0)

        let item = CommandPaletteItem(
            id: "a",
            title: "A",
            subtitle: nil,
            iconSystemName: "music.note",
            section: .tracks,
            keywords: [],
            action: {}
        )
        viewModel.testingReplaceSections([(.tracks, [item])])
        viewModel.selectedIndex = 0
        viewModel.moveSelection(delta: 5)
        XCTAssertEqual(viewModel.selectedIndex, 0)
        viewModel.moveSelection(delta: -1)
        XCTAssertEqual(viewModel.selectedIndex, 0)
    }

    func testExecuteSelectionDoesNotDismissForUnavailableItem() async {
        let viewModel = CommandPaletteViewModel()
        viewModel.show()
        var didExecute = false
        let unavailable = CommandPaletteItem(
            id: "unavailable",
            title: "Play/Pause",
            subtitle: nil,
            iconSystemName: "playpause",
            section: .commands,
            keywords: [],
            canExecute: { false },
            action: { didExecute = true }
        )
        viewModel.testingReplaceSections([(.commands, [unavailable])])
        await viewModel.executeSelection()
        XCTAssertTrue(viewModel.isPresented)
        XCTAssertFalse(didExecute)
    }

    func testExecuteSelectionHidesUnlessKeepsPaletteOpen() async {
        let viewModel = CommandPaletteViewModel()
        viewModel.show()
        let closing = CommandPaletteItem(
            id: "close",
            title: "Close",
            subtitle: nil,
            iconSystemName: "gear",
            section: .commands,
            keywords: [],
            action: {}
        )
        viewModel.testingReplaceSections([(.commands, [closing])])
        viewModel.selectedIndex = 0
        await viewModel.executeSelection()
        XCTAssertFalse(viewModel.isPresented)

        viewModel.show()
        let staying = CommandPaletteItem(
            id: "stay",
            title: "Stay",
            subtitle: nil,
            iconSystemName: "gear",
            section: .commands,
            keywords: [],
            keepsPaletteOpen: true,
            action: {}
        )
        viewModel.testingReplaceSections([(.commands, [staying])])
        await viewModel.executeSelection()
        XCTAssertTrue(viewModel.isPresented)
    }

    func testExecuteSelectionUnpinAndEnqueue() async {
        let viewModel = CommandPaletteViewModel()
        var didUnpin = false
        var didEnqueue = false
        let item = CommandPaletteItem(
            id: "track",
            title: "Track",
            subtitle: nil,
            iconSystemName: "music.note",
            section: .tracks,
            keywords: [],
            unpinAction: { didUnpin = true },
            queueAction: { didEnqueue = true },
            action: {}
        )
        viewModel.testingReplaceSections([(.tracks, [item])])
        viewModel.selectedIndex = 0
        await viewModel.executeSelectionUnpinning()
        await viewModel.executeSelectionEnqueue()
        XCTAssertTrue(didUnpin)
        XCTAssertTrue(didEnqueue)
        XCTAssertTrue(viewModel.canEnqueueSelectedItem)
    }

    func testSetAvailableSearchCategoriesInvalidatesFilterAndRefreshes() async {
        let viewModel = CommandPaletteViewModel()
        var callCount = 0
        viewModel.searchProvider = { _, _ in
            callCount += 1
            return CommandPaletteSearchResults()
        }
        viewModel.show()
        viewModel.searchCategoryFilter = .tracks
        viewModel.query = "abc"
        viewModel.setAvailableSearchCategories([.artists, .myPlaylists], refreshIfFilterInvalidated: true)
        XCTAssertEqual(viewModel.searchCategoryFilter, .artists)
        await viewModel.waitForSearchCompletion()
        XCTAssertGreaterThanOrEqual(callCount, 1)
    }

    func testCommandScopeFiltersStaticItems() async {
        let viewModel = CommandPaletteViewModel()
        viewModel.staticItemsProvider = {
            [
                CommandPaletteItem(id: "match", title: "Play Next", subtitle: nil, iconSystemName: "forward", section: .commands, keywords: ["queue"], action: {}),
                CommandPaletteItem(id: "other", title: "Settings", subtitle: nil, iconSystemName: "gear", section: .commands, keywords: [], action: {})
            ]
        }
        viewModel.show()
        viewModel.query = ">play"
        viewModel.refresh()
        await viewModel.waitForSearchCompletion()
        XCTAssertEqual(viewModel.sections.count, 1)
        XCTAssertEqual(viewModel.sections.first?.items.map(\.id), ["match"])
    }

    func testPerformSearchGenericErrorSetsErrorText() async {
        let viewModel = CommandPaletteViewModel()
        viewModel.searchProvider = { _, _ in
            struct Sample: Error {}
            throw Sample()
        }
        viewModel.show()
        viewModel.query = "abcd"
        viewModel.refresh()
        await viewModel.waitForSearchCompletion()
        XCTAssertNotNil(viewModel.errorText)
        XCTAssertTrue(viewModel.sections.isEmpty)
    }
}
