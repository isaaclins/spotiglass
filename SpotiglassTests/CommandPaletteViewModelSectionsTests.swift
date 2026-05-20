import XCTest
@testable import Spotiglass

@MainActor
final class CommandPaletteViewModelSectionsTests: XCTestCase {
    /// Configures categories and filter before presentation so `show()` does not reset an invalid `.thisPlaylist` filter.
    private func prepareSongSearch(
        _ viewModel: CommandPaletteViewModel,
        includeThisPlaylist: Bool = false,
        category: CommandPaletteSearchCategory = .all
    ) {
        viewModel.setAvailableSearchCategories(
            CommandPaletteSearchCategory.footerOrder(includeThisPlaylist: includeThisPlaylist),
            refreshIfFilterInvalidated: false
        )
        viewModel.show()
        viewModel.searchCategoryFilter = category
    }

    private func waitForPaletteSearch(
        _ viewModel: CommandPaletteViewModel,
        until sectionsCount: Int,
        timeout: TimeInterval = 2
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !viewModel.isLoading, viewModel.sections.count == sectionsCount {
                return
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    func testLegacyAtPrefixSetsArtistCategoryAndStripsQuery() async {
        let viewModel = CommandPaletteViewModel()
        defer { viewModel.hide() }
        viewModel.searchProvider = { _, _ in CommandPaletteSearchResults() }

        viewModel.show()
        viewModel.query = "@m83"
        viewModel.refresh()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(viewModel.searchCategoryFilter, .artists)
        XCTAssertEqual(viewModel.query, "m83")
    }

    func testTracksCategoryEmitsOnlyTracksSection() async {
        let viewModel = CommandPaletteViewModel()
        defer { viewModel.hide() }
        viewModel.staticItemsProvider = {
            [
                CommandPaletteItem(
                    id: "static-1",
                    title: "Refresh Playlists",
                    subtitle: nil,
                    iconSystemName: "arrow.clockwise",
                    section: .commands,
                    keywords: ["refresh"]
                ) {}
            ]
        }
        viewModel.searchProvider = { _, _ in
            CommandPaletteSearchResults(
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

        prepareSongSearch(viewModel, category: .tracks)
        viewModel.query = "midnight"
        viewModel.refresh()
        await waitForPaletteSearch(viewModel, until: 1)

        XCTAssertEqual(viewModel.sections.count, 1)
        XCTAssertEqual(viewModel.sections.first?.section, .tracks)
        XCTAssertEqual(viewModel.sections.first?.items.map(\.id), ["track-1"])
        XCTAssertEqual(viewModel.visibleItems.map(\.id), ["track-1"])
    }

    func testAllCategoryEmitsPlaylistsThisPlaylistTracksArtistsAlbumsInOrder() async {
        let viewModel = CommandPaletteViewModel()
        defer { viewModel.hide() }
        viewModel.searchProvider = { _, _ in
            CommandPaletteSearchResults(
                tracks: [
                    CommandPaletteItem(
                        id: "track-1",
                        title: "Song",
                        subtitle: "Artist",
                        iconSystemName: "music.note",
                        section: .tracks,
                        keywords: []
                    ) {}
                ],
                artists: [
                    CommandPaletteItem(
                        id: "artist-1",
                        title: "Band",
                        subtitle: "Artist",
                        iconSystemName: "person.wave.2",
                        section: .artists,
                        keywords: []
                    ) {}
                ],
                albums: [
                    CommandPaletteItem(
                        id: "album-1",
                        title: "Album",
                        subtitle: "Artist",
                        iconSystemName: "opticaldisc",
                        section: .albums,
                        keywords: []
                    ) {}
                ],
                catalogPlaylists: [
                    CommandPaletteItem(
                        id: "playlist-a",
                        title: "Workout",
                        subtitle: "Owner",
                        iconSystemName: "music.note.list",
                        section: .playlists,
                        keywords: []
                    ) {}
                ],
                inPlaylistMatches: [
                    CommandPaletteItem(
                        id: "track-local",
                        title: "Local Hit",
                        subtitle: "Artist",
                        iconSystemName: "music.note",
                        section: .thisPlaylist,
                        keywords: []
                    ) {}
                ]
            )
        }

        prepareSongSearch(viewModel, includeThisPlaylist: true, category: .all)
        viewModel.query = "any"
        viewModel.refresh()
        await waitForPaletteSearch(viewModel, until: 5)

        XCTAssertEqual(viewModel.sections.count, 5)
        XCTAssertEqual(viewModel.sections.map(\.section), [.playlists, .thisPlaylist, .tracks, .artists, .albums])
        XCTAssertEqual(viewModel.visibleItems.map(\.id), ["playlist-a", "track-local", "track-1", "artist-1", "album-1"])
    }

    func testArtistsCategoryEmitsOnlyArtistsSection() async {
        let viewModel = CommandPaletteViewModel()
        defer { viewModel.hide() }
        viewModel.searchProvider = { _, _ in
            CommandPaletteSearchResults(
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

        prepareSongSearch(viewModel, category: .artists)
        viewModel.query = "m83"
        viewModel.refresh()
        await waitForPaletteSearch(viewModel, until: 1)

        XCTAssertEqual(viewModel.sections.count, 1)
        XCTAssertEqual(viewModel.sections.first?.section, .artists)
        XCTAssertEqual(viewModel.sections.first?.items.map(\.id), ["artist-1"])
    }

    func testThisPlaylistCategoryEmitsOnlyThisPlaylistSection() async {
        let viewModel = CommandPaletteViewModel()
        defer { viewModel.hide() }
        viewModel.searchProvider = { _, _ in
            CommandPaletteSearchResults(
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
                inPlaylistMatches: [
                    CommandPaletteItem(
                        id: "track-in-pl",
                        title: "In List",
                        subtitle: "M83",
                        iconSystemName: "music.note",
                        section: .thisPlaylist,
                        keywords: []
                    ) {}
                ]
            )
        }

        prepareSongSearch(viewModel, includeThisPlaylist: true, category: .thisPlaylist)
        viewModel.query = "list"
        viewModel.refresh()
        await waitForPaletteSearch(viewModel, until: 1)

        XCTAssertEqual(viewModel.sections.count, 1)
        XCTAssertEqual(viewModel.sections.first?.section, .thisPlaylist)
        XCTAssertEqual(viewModel.sections.first?.items.map(\.id), ["track-in-pl"])
    }

    func testMyPlaylistsCategoryEmitsOnlyMyPlaylistsSection() async {
        let viewModel = CommandPaletteViewModel()
        defer { viewModel.hide() }
        viewModel.searchProvider = { _, _ in
            CommandPaletteSearchResults(
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
                catalogPlaylists: [
                    CommandPaletteItem(
                        id: "playlist-cat",
                        title: "Spotify List",
                        subtitle: "Owner",
                        iconSystemName: "music.note.list",
                        section: .playlists,
                        keywords: []
                    ) {}
                ],
                myPlaylists: [
                    CommandPaletteItem(
                        id: "playlist-lib",
                        title: "My List",
                        subtitle: "Your library • me",
                        iconSystemName: "music.note.list",
                        section: .myPlaylists,
                        keywords: []
                    ) {}
                ]
            )
        }

        prepareSongSearch(viewModel, category: .myPlaylists)
        viewModel.query = "list"
        viewModel.refresh()
        await waitForPaletteSearch(viewModel, until: 1)

        XCTAssertEqual(viewModel.sections.count, 1)
        XCTAssertEqual(viewModel.sections.first?.section, .myPlaylists)
        XCTAssertEqual(viewModel.sections.first?.items.map(\.id), ["playlist-lib"])
    }

    func testAllCategoryMergesCatalogPlaylistsThenLibraryNotAlreadyInCatalog() async {
        let viewModel = CommandPaletteViewModel()
        defer { viewModel.hide() }
        viewModel.searchProvider = { _, _ in
            CommandPaletteSearchResults(
                catalogPlaylists: [
                    CommandPaletteItem(
                        id: "playlist-shared",
                        title: "Shared",
                        subtitle: "Playlist • Spotify",
                        iconSystemName: "music.note.list",
                        section: .playlists,
                        keywords: []
                    ) {}
                ],
                myPlaylists: [
                    CommandPaletteItem(
                        id: "playlist-shared",
                        title: "Shared",
                        subtitle: "Your library • me",
                        iconSystemName: "music.note.list",
                        section: .myPlaylists,
                        keywords: []
                    ) {},
                    CommandPaletteItem(
                        id: "playlist-only-lib",
                        title: "Only Mine",
                        subtitle: "Your library • me",
                        iconSystemName: "music.note.list",
                        section: .myPlaylists,
                        keywords: []
                    ) {}
                ]
            )
        }

        prepareSongSearch(viewModel, category: .all)
        viewModel.query = "any"
        viewModel.refresh()
        await waitForPaletteSearch(viewModel, until: 1)

        XCTAssertEqual(viewModel.sections.count, 1)
        XCTAssertEqual(viewModel.sections.first?.section, .playlists)
        XCTAssertEqual(viewModel.sections.first?.items.map(\.id), ["playlist-shared", "playlist-only-lib"])
    }

    func testCommandsScopeEmitsOnlyCommandsSection() async {
        let viewModel = CommandPaletteViewModel()
        defer { viewModel.hide() }
        viewModel.staticItemsProvider = {
            [
                CommandPaletteItem(
                    id: "cmd-1",
                    title: "Refresh Playlists",
                    subtitle: nil,
                    iconSystemName: "arrow.clockwise",
                    section: .commands,
                    keywords: []
                ) {},
                CommandPaletteItem(
                    id: "cmd-2",
                    title: "Open Settings",
                    subtitle: nil,
                    iconSystemName: "gearshape",
                    section: .commands,
                    keywords: []
                ) {}
            ]
        }
        viewModel.searchProvider = { _, _ in
            CommandPaletteSearchResults(
                tracks: [
                    CommandPaletteItem(
                        id: "track-1",
                        title: "Refresh Track",
                        subtitle: nil,
                        iconSystemName: "music.note",
                        section: .tracks,
                        keywords: []
                    ) {}
                ]
            )
        }

        viewModel.show()
        viewModel.query = ">"
        viewModel.refresh()
        await waitForPaletteSearch(viewModel, until: 1)

        XCTAssertEqual(viewModel.sections.count, 1)
        XCTAssertEqual(viewModel.sections.first?.section, .commands)
        XCTAssertEqual(Set(viewModel.sections.first?.items.map(\.id) ?? []), ["cmd-1", "cmd-2"])
    }

    func testNoResultsLeavesSectionsEmptyForNonEmptyQuery() async {
        let viewModel = CommandPaletteViewModel()
        defer { viewModel.hide() }
        viewModel.searchProvider = { _, _ in
            CommandPaletteSearchResults()
        }

        prepareSongSearch(viewModel, category: .tracks)
        viewModel.query = "nothing"
        viewModel.refresh()
        await waitForPaletteSearch(viewModel, until: 0)

        XCTAssertTrue(viewModel.sections.isEmpty)
        XCTAssertTrue(viewModel.visibleItems.isEmpty)
    }
}
