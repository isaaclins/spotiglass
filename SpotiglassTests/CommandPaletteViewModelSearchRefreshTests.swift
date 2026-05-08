import XCTest
@testable import Spotiglass

@MainActor
final class CommandPaletteViewModelSearchRefreshTests: XCTestCase {
    func testSingleCharacterQueryDoesNotInvokeSearchProvider() async {
        let viewModel = CommandPaletteViewModel()
        var callCount = 0
        viewModel.searchProvider = { _, _ in
            callCount += 1
            return CommandPaletteSearchResults()
        }
        viewModel.show()
        viewModel.query = "a"
        viewModel.refresh()
        try? await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(callCount, 0)
    }

    func testDuplicateRefreshSkipsSearchProviderWhenKeyUnchanged() async {
        let viewModel = CommandPaletteViewModel()
        var callCount = 0
        viewModel.searchProvider = { _, _ in
            callCount += 1
            return CommandPaletteSearchResults(
                tracks: [
                    CommandPaletteItem(
                        id: "track-1",
                        title: "Song",
                        subtitle: "Artist",
                        iconSystemName: "music.note",
                        section: .tracks,
                        keywords: []
                    ) {}
                ]
            )
        }
        viewModel.show()
        viewModel.query = "ab"
        viewModel.refresh()
        try? await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(callCount, 1)
        viewModel.refresh()
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(callCount, 1)
    }

    func testShorteningQueryBelowMinCharThenRestoringRefetches() async {
        let viewModel = CommandPaletteViewModel()
        var callCount = 0
        viewModel.searchProvider = { _, _ in
            callCount += 1
            return CommandPaletteSearchResults(
                tracks: [
                    CommandPaletteItem(
                        id: "track-1",
                        title: "Song",
                        subtitle: "Artist",
                        iconSystemName: "music.note",
                        section: .tracks,
                        keywords: []
                    ) {}
                ]
            )
        }
        viewModel.show()
        viewModel.query = "ab"
        viewModel.refresh()
        try? await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(callCount, 1)
        viewModel.query = "a"
        viewModel.refresh()
        try? await Task.sleep(for: .milliseconds(120))
        viewModel.query = "ab"
        viewModel.refresh()
        try? await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(callCount, 2)
    }

    func testRapidCategoryCyclesCoalesceToSingleSearchProviderCall() async {
        let viewModel = CommandPaletteViewModel()
        var callCount = 0
        viewModel.searchProvider = { _, _ in
            callCount += 1
            return CommandPaletteSearchResults()
        }
        viewModel.show()
        viewModel.setAvailableSearchCategories(CommandPaletteSearchCategory.footerOrder(includeThisPlaylist: false), refreshIfFilterInvalidated: false)
        viewModel.query = "abc"
        for _ in 0 ..< 5 {
            viewModel.cycleSearchCategory(forward: true)
        }
        try? await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(callCount, 1)
    }

    func testRateLimitedSearchSetsCooldownAndSkipsFollowUpProviderCalls() async {
        let viewModel = CommandPaletteViewModel()
        var callCount = 0
        viewModel.searchProvider = { _, _ in
            callCount += 1
            throw SpotifyAPIError.rateLimited(retryAfter: 3)
        }
        viewModel.show()
        viewModel.query = "ab"
        viewModel.refresh()
        try? await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(callCount, 1)
        viewModel.searchProvider = { _, _ in
            callCount += 1
            return CommandPaletteSearchResults()
        }
        viewModel.refresh()
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(callCount, 1, "Palette should honor cooldown and not dispatch another search immediately")
    }

    func testLegacyAtPrefixSongSearchCallsProviderOnceForNormalizedQuery() async {
        let viewModel = CommandPaletteViewModel()
        var invocations: [String] = []
        viewModel.searchProvider = { query, _ in
            invocations.append(query)
            return CommandPaletteSearchResults()
        }
        viewModel.show()
        viewModel.query = "@m83"
        viewModel.refresh()
        try? await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(invocations, ["m83"])
    }
}
