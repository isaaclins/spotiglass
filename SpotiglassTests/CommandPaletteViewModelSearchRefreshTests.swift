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
        await viewModel.waitForSearchCompletion()
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
        await viewModel.waitForSearchCompletion()
        XCTAssertEqual(callCount, 1)
        viewModel.refresh()
        await viewModel.waitForSearchCompletion()
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
        await viewModel.waitForSearchCompletion()
        XCTAssertEqual(callCount, 1)
        viewModel.query = "a"
        viewModel.refresh()
        await viewModel.waitForSearchCompletion()
        viewModel.query = "ab"
        viewModel.refresh()
        await viewModel.waitForSearchCompletion()
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
        await viewModel.waitForSearchCompletion()
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
        await viewModel.waitForSearchCompletion()
        XCTAssertEqual(callCount, 1)
        viewModel.searchProvider = { _, _ in
            callCount += 1
            return CommandPaletteSearchResults()
        }
        viewModel.refresh()
        await viewModel.waitForSearchCompletion()
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
        await viewModel.waitForSearchCompletion()
        XCTAssertEqual(invocations, ["m83"])
    }

    func testLocalResultsRenderInstantlyBeforeCatalogProviderReturns() async {
        let viewModel = CommandPaletteViewModel()
        defer { viewModel.hide() }
        viewModel.localResultsProvider = { _ in
            CommandPaletteSearchResults(
                myPlaylists: [
                    CommandPaletteItem(
                        id: "playlist-local",
                        title: "Local Mix",
                        subtitle: nil,
                        iconSystemName: "music.note.list",
                        section: .myPlaylists,
                        keywords: []
                    ) {}
                ]
            )
        }
        var networkCalls = 0
        let releaseNetworkCall = AsyncSignal()
        viewModel.searchProvider = { _, _ in
            networkCalls += 1
            await releaseNetworkCall.wait()
            return CommandPaletteSearchResults()
        }
        viewModel.show()
        viewModel.searchCategoryFilter = .all
        viewModel.query = "local"
        viewModel.refresh()

        // refresh() paints local matches synchronously — before the debounce/network fires.
        XCTAssertEqual(viewModel.visibleItems.map(\.id), ["playlist-local"])
        XCTAssertEqual(networkCalls, 0)
        releaseNetworkCall.signal()
        await viewModel.waitForSearchCompletion()
    }

    func testSwitchingCategoryAfterSearchFiltersFromCacheWithoutRefetch() async {
        let viewModel = CommandPaletteViewModel()
        defer { viewModel.hide() }
        var networkCalls = 0
        viewModel.searchProvider = { _, _ in
            networkCalls += 1
            return CommandPaletteSearchResults(
                tracks: [
                    CommandPaletteItem(
                        id: "track-1",
                        title: "Midnight City",
                        subtitle: "M83",
                        iconSystemName: "music.note",
                        section: .tracks,
                        keywords: []
                    ) {}
                ],
                artists: [
                    CommandPaletteItem(
                        id: "artist-1",
                        title: "M83",
                        subtitle: "Artist",
                        iconSystemName: "person.wave.2",
                        section: .artists,
                        keywords: []
                    ) {}
                ]
            )
        }
        viewModel.setAvailableSearchCategories(CommandPaletteSearchCategory.footerOrder(includeThisPlaylist: false), refreshIfFilterInvalidated: false)
        viewModel.show()
        viewModel.searchCategoryFilter = .all
        viewModel.query = "midnight"
        viewModel.refresh()
        await viewModel.waitForSearchCompletion()
        XCTAssertEqual(networkCalls, 1)

        viewModel.selectCategory(.artists)
        XCTAssertEqual(networkCalls, 1, "Switching pills must re-filter the cache, not re-query")
        XCTAssertEqual(viewModel.sections.map(\.section), [.artists])
        XCTAssertEqual(viewModel.visibleItems.map(\.id), ["artist-1"])

        viewModel.selectCategory(.tracks)
        XCTAssertEqual(networkCalls, 1)
        XCTAssertEqual(viewModel.visibleItems.map(\.id), ["track-1"])
    }

    func testAllCategoryFloatsBestMatchingSectionFirst() async {
        let viewModel = CommandPaletteViewModel()
        defer { viewModel.hide() }
        viewModel.searchProvider = { _, _ in
            CommandPaletteSearchResults(
                tracks: [
                    CommandPaletteItem(
                        id: "track-1",
                        title: "Some Song",
                        subtitle: "Other Band",
                        iconSystemName: "music.note",
                        section: .tracks,
                        keywords: []
                    ) {}
                ],
                artists: [
                    CommandPaletteItem(
                        id: "artist-1",
                        title: "Kanye West",
                        subtitle: "Artist",
                        iconSystemName: "person.wave.2",
                        section: .artists,
                        keywords: []
                    ) {}
                ]
            )
        }
        viewModel.setAvailableSearchCategories(CommandPaletteSearchCategory.footerOrder(includeThisPlaylist: false), refreshIfFilterInvalidated: false)
        viewModel.show()
        viewModel.searchCategoryFilter = .all
        viewModel.query = "kanye"
        viewModel.refresh()
        await viewModel.waitForSearchCompletion()

        // "kanye" matches the artist (prefix) but not the track, so Artists floats above Tracks.
        XCTAssertEqual(viewModel.sections.map(\.section), [.artists, .tracks])
    }
}
