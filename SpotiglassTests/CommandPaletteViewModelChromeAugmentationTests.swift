import XCTest

@testable import Spotiglass

@MainActor
final class CommandPaletteViewModelChromeAugmentationTests: XCTestCase {
    func testKeepsPaletteOpenSkipsHide() async {
        let viewModel = CommandPaletteViewModel()
        viewModel.staticItemsProvider = {
            [
                CommandPaletteItem(
                    id: "stays-open",
                    title: "Stays Open",
                    subtitle: nil,
                    iconSystemName: "arrow.right",
                    section: .commands,
                    keywords: [],
                    keepsPaletteOpen: true
                ) {}
            ]
        }
        viewModel.show()
        viewModel.query = ">"
        viewModel.refresh()
        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(viewModel.visibleItems.count, 1)
        await viewModel.executeSelection()
        XCTAssertTrue(viewModel.isPresented, "Items with keepsPaletteOpen should not dismiss the palette")
    }

    func testSetAvailableSearchCategoriesCoercesThisPlaylistWhenSegmentRemoved() {
        let viewModel = CommandPaletteViewModel()
        viewModel.setAvailableSearchCategories(
            CommandPaletteSearchCategory.footerOrder(includeThisPlaylist: true), refreshIfFilterInvalidated: false)
        viewModel.searchCategoryFilter = .thisPlaylist
        viewModel.setAvailableSearchCategories(
            CommandPaletteSearchCategory.footerOrder(includeThisPlaylist: false), refreshIfFilterInvalidated: false)
        XCTAssertEqual(viewModel.searchCategoryFilter, .all)
    }

    func testAugmentationShouldFetchWhenQueryMatchesArtistName() {
        XCTAssertTrue(
            SpotifyPaletteSearchAugmentation.shouldFetchArtistScopedTracks(
                trimmedUserQuery: "kanye", topArtistName: "Kanye West", primaryTrackCount: 0)
        )
        XCTAssertTrue(
            SpotifyPaletteSearchAugmentation.shouldFetchArtistScopedTracks(
                trimmedUserQuery: "kanye west", topArtistName: "Kanye West", primaryTrackCount: 0)
        )
        XCTAssertFalse(
            SpotifyPaletteSearchAugmentation.shouldFetchArtistScopedTracks(
                trimmedUserQuery: "love", topArtistName: "The Beatles", primaryTrackCount: 0)
        )
        XCTAssertFalse(
            SpotifyPaletteSearchAugmentation.shouldFetchArtistScopedTracks(
                trimmedUserQuery: "kanye", topArtistName: "Kanye West", primaryTrackCount: 6)
        )
    }

    func testAugmentationMergeTracksDedupesById() {
        let a = SpotifyTrack(
            id: "t1",
            name: "A",
            artists: ["X"],
            albumArtworkURL: nil,
            durationMilliseconds: 1,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "spotify:track:t1"
        )
        let b = SpotifyTrack(
            id: "t2",
            name: "B",
            artists: ["Y"],
            albumArtworkURL: nil,
            durationMilliseconds: 1,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "spotify:track:t2"
        )
        let dup = SpotifyTrack(
            id: "t1",
            name: "A2",
            artists: ["X"],
            albumArtworkURL: nil,
            durationMilliseconds: 1,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "spotify:track:t1"
        )
        let merged = SpotifyPaletteSearchAugmentation.mergeTracksPreservingOrder(primary: [a], extra: [b, dup])
        XCTAssertEqual(merged.map(\.id), ["t1", "t2"])
    }
}
