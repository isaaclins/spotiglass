import AppKit
import XCTest
@testable import Spotiglass

@MainActor
final class CommandPaletteTests: XCTestCase {
    func testFooterOrderPrioritizesHereTracksArtists() {
        XCTAssertEqual(
            CommandPaletteSearchCategory.footerOrder(includeThisPlaylist: true),
            [.thisPlaylist, .tracks, .artists, .all, .myPlaylists]
        )
        XCTAssertEqual(
            CommandPaletteSearchCategory.footerOrder(includeThisPlaylist: false),
            [.tracks, .artists, .all, .myPlaylists]
        )
    }

    func testThisPlaylistSectionUsesHereDisplayLabel() {
        XCTAssertEqual(CommandPaletteSection.thisPlaylist.displayLabel, "HERE")
    }

    func testShortcutParsingSupportsModifiers() throws {
        let shortcut = try CommandShortcut(keystroke: "shift-cmd-k")
        XCTAssertEqual(shortcut.key, "k")
        XCTAssertTrue(shortcut.modifiers.contains(.command))
        XCTAssertTrue(shortcut.modifiers.contains(.shift))
    }

    func testCanonicalTokenRoundTrips() throws {
        let keystrokes = ["shift-cmd-k", "cmd-,", "space", "shift-cmd-right", "shift-cmd-left", "ctrl-alt-shift-cmd-a"]
        for ks in keystrokes {
            let shortcut = try CommandShortcut(keystroke: ks)
            let token = try shortcut.canonicalToken()
            let roundTrip = try CommandShortcut(keystroke: token)
            XCTAssertEqual(shortcut, roundTrip, "Round-trip failed for \(ks) → \(token)")
        }
    }

    func testConflictingCommandIDDetectsOverlappingAlwaysBindings() throws {
        let url = makeTempSettingsURL()
        let settingsStore = SpotiglassSettingsStore(fileURL: url)
        let store = CommandPaletteKeymapStore(settingsStore: settingsStore)
        let cmdK = try CommandShortcut(keystroke: "cmd-k")
        let other = store.conflictingCommandID(for: cmdK, proposedForCommand: CommandPaletteCommandID.openSettings)
        XCTAssertEqual(other, CommandPaletteCommandID.openPalette)
    }

    func testSetBindingPersistsAndClears() throws {
        let url = makeTempSettingsURL()
        let settingsStore = SpotiglassSettingsStore(fileURL: url)
        let store = CommandPaletteKeymapStore(settingsStore: settingsStore)
        let newShortcut = try CommandShortcut(keystroke: "shift-cmd-9")
        try store.setBinding(commandID: CommandPaletteCommandID.openSettings, shortcut: newShortcut, replaceConflicting: false)
        XCTAssertEqual(store.primaryShortcut(for: CommandPaletteCommandID.openSettings), newShortcut)

        let file = try JSONDecoder().decode(CommandPaletteKeymapFile.self, from: Data(store.editorText.utf8))
        let row = file.bindings.first { $0.command == CommandPaletteCommandID.openSettings }
        XCTAssertEqual(row?.keystrokes, ["shift-cmd-9"])

        // Confirm the merged settings.json on disk also reflects the change.
        let onDisk = try JSONDecoder().decode(SpotiglassSettingsFile.self, from: try Data(contentsOf: url))
        let onDiskRow = onDisk.keybinds.first { $0.command == CommandPaletteCommandID.openSettings }
        XCTAssertEqual(onDiskRow?.keystrokes, ["shift-cmd-9"])

        try store.clearBinding(commandID: CommandPaletteCommandID.openSettings)
        XCTAssertNil(store.primaryShortcut(for: CommandPaletteCommandID.openSettings))
    }

    func testSetBindingThrowsConflictUnlessReplace() throws {
        let url = makeTempSettingsURL()
        let settingsStore = SpotiglassSettingsStore(fileURL: url)
        let store = CommandPaletteKeymapStore(settingsStore: settingsStore)
        let stolen = try CommandShortcut(keystroke: "cmd-k")
        XCTAssertThrowsError(
            try store.setBinding(commandID: CommandPaletteCommandID.openSettings, shortcut: stolen, replaceConflicting: false)
        ) { error in
            XCTAssertEqual(
                error as? KeymapConflictError,
                .conflict(existingCommandID: CommandPaletteCommandID.openPalette)
            )
        }
        try store.setBinding(commandID: CommandPaletteCommandID.openSettings, shortcut: stolen, replaceConflicting: true)
        XCTAssertEqual(store.primaryShortcut(for: CommandPaletteCommandID.openSettings), stolen)
        XCTAssertNil(store.primaryShortcut(for: CommandPaletteCommandID.openPalette))
    }

    private func makeTempSettingsURL() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
        }
        return dir.appendingPathComponent("settings.json", isDirectory: false)
    }

    func testKeymapDecodingParsesContextAndArgs() throws {
        let json = """
        {
          "bindings": [
            {
              "keystrokes": ["cmd-k"],
              "command": "palette.open",
              "when": "always",
              "args": { "uri": "spotify:track:1" }
            }
          ]
        }
        """

        let file = try JSONDecoder().decode(CommandPaletteKeymapFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.bindings.count, 1)
        XCTAssertEqual(file.bindings[0].command, "palette.open")
        XCTAssertEqual(file.bindings[0].when, .always)
        XCTAssertEqual(file.bindings[0].args?["uri"], .string("spotify:track:1"))
    }

    func testManagerOpenPaletteCommandShowsOverlay() {
        let manager = CommandPaletteManager()
        XCTAssertFalse(manager.viewModel.isPresented)
        manager.execute(commandID: CommandPaletteCommandID.openPalette)
        XCTAssertTrue(manager.viewModel.isPresented)
    }

    func testOpenArtistCommandInvokesHandler() async {
        let manager = CommandPaletteManager()
        let expectation = expectation(description: "openArtist")
        var receivedID: String?
        manager.openArtist = { id in
            receivedID = id
            expectation.fulfill()
        }
        manager.execute(commandID: CommandPaletteCommandID.openArtist, args: ["artistID": .string("abc123")])
        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(receivedID, "abc123")
    }

    func testToggleLyricsCommandInvokesHandler() {
        let manager = CommandPaletteManager()
        var toggled = false
        manager.toggleLyrics = { toggled = true }
        manager.execute(commandID: CommandPaletteCommandID.toggleLyrics)
        XCTAssertTrue(toggled)
    }

    // MARK: - Scope parser

    func testScopeParseEmptyDefaultsToSongs() {
        let result = CommandPaletteScope.parse("")
        XCTAssertEqual(result.scope, .songs)
        XCTAssertEqual(result.query, "")
    }

    func testScopeParsePlainQueryDefaultsToSongs() {
        let result = CommandPaletteScope.parse("midnight")
        XCTAssertEqual(result.scope, .songs)
        XCTAssertEqual(result.query, "midnight")
    }

    func testScopeParseGreaterThanPrefixYieldsCommandsScope() {
        let bare = CommandPaletteScope.parse(">")
        XCTAssertEqual(bare.scope, .commands)
        XCTAssertEqual(bare.query, "")

        let withQuery = CommandPaletteScope.parse(">refresh")
        XCTAssertEqual(withQuery.scope, .commands)
        XCTAssertEqual(withQuery.query, "refresh")
    }

    func testScopeParseAtPrefixIsStillSongsScopeQueryUnchanged() {
        let bare = CommandPaletteScope.parse("@")
        XCTAssertEqual(bare.scope, .songs)
        XCTAssertEqual(bare.query, "@")

        let withQuery = CommandPaletteScope.parse("@malcolm")
        XCTAssertEqual(withQuery.scope, .songs)
        XCTAssertEqual(withQuery.query, "@malcolm")
    }

    func testLegacyAtPrefixSetsArtistCategoryAndStripsQuery() async {
        let viewModel = CommandPaletteViewModel()
        viewModel.searchProvider = { _, _ in CommandPaletteSearchResults() }

        viewModel.show()
        viewModel.query = "@m83"
        viewModel.refresh()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(viewModel.searchCategoryFilter, .artists)
        XCTAssertEqual(viewModel.query, "m83")
    }

    // MARK: - Sectioned view-model state

    func testTracksCategoryEmitsOnlyTracksSection() async {
        let viewModel = CommandPaletteViewModel()
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

        viewModel.show()
        viewModel.searchCategoryFilter = .tracks
        viewModel.query = "midnight"
        viewModel.refresh()
        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(viewModel.sections.count, 1)
        XCTAssertEqual(viewModel.sections.first?.section, .tracks)
        XCTAssertEqual(viewModel.sections.first?.items.map(\.id), ["track-1"])
        XCTAssertEqual(viewModel.visibleItems.map(\.id), ["track-1"])
    }

    func testAllCategoryEmitsPlaylistsThisPlaylistTracksArtistsAlbumsInOrder() async {
        let viewModel = CommandPaletteViewModel()
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

        viewModel.show()
        viewModel.searchCategoryFilter = .all
        viewModel.query = "any"
        viewModel.refresh()
        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(viewModel.sections.count, 5)
        XCTAssertEqual(viewModel.sections.map(\.section), [.playlists, .thisPlaylist, .tracks, .artists, .albums])
        XCTAssertEqual(viewModel.visibleItems.map(\.id), ["playlist-a", "track-local", "track-1", "artist-1", "album-1"])
    }

    func testArtistsCategoryEmitsOnlyArtistsSection() async {
        let viewModel = CommandPaletteViewModel()
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

        viewModel.show()
        viewModel.searchCategoryFilter = .artists
        viewModel.query = "m83"
        viewModel.refresh()
        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(viewModel.sections.count, 1)
        XCTAssertEqual(viewModel.sections.first?.section, .artists)
        XCTAssertEqual(viewModel.sections.first?.items.map(\.id), ["artist-1"])
    }

    func testThisPlaylistCategoryEmitsOnlyThisPlaylistSection() async {
        let viewModel = CommandPaletteViewModel()
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

        viewModel.show()
        viewModel.setAvailableSearchCategories(CommandPaletteSearchCategory.footerOrder(includeThisPlaylist: true))
        viewModel.searchCategoryFilter = .thisPlaylist
        viewModel.query = "list"
        viewModel.refresh()
        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(viewModel.sections.count, 1)
        XCTAssertEqual(viewModel.sections.first?.section, .thisPlaylist)
        XCTAssertEqual(viewModel.sections.first?.items.map(\.id), ["track-in-pl"])
    }

    func testMyPlaylistsCategoryEmitsOnlyMyPlaylistsSection() async {
        let viewModel = CommandPaletteViewModel()
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

        viewModel.show()
        viewModel.searchCategoryFilter = .myPlaylists
        viewModel.query = "list"
        viewModel.refresh()
        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(viewModel.sections.count, 1)
        XCTAssertEqual(viewModel.sections.first?.section, .myPlaylists)
        XCTAssertEqual(viewModel.sections.first?.items.map(\.id), ["playlist-lib"])
    }

    func testAllCategoryMergesCatalogPlaylistsThenLibraryNotAlreadyInCatalog() async {
        let viewModel = CommandPaletteViewModel()
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

        viewModel.show()
        viewModel.searchCategoryFilter = .all
        viewModel.query = "any"
        viewModel.refresh()
        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(viewModel.sections.count, 1)
        XCTAssertEqual(viewModel.sections.first?.section, .playlists)
        XCTAssertEqual(viewModel.sections.first?.items.map(\.id), ["playlist-shared", "playlist-only-lib"])
    }

    func testCommandsScopeEmitsOnlyCommandsSection() async {
        let viewModel = CommandPaletteViewModel()
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
        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(viewModel.sections.count, 1)
        XCTAssertEqual(viewModel.sections.first?.section, .commands)
        XCTAssertEqual(Set(viewModel.sections.first?.items.map(\.id) ?? []), ["cmd-1", "cmd-2"])
    }

    func testNoResultsLeavesSectionsEmptyForNonEmptyQuery() async {
        let viewModel = CommandPaletteViewModel()
        viewModel.searchProvider = { _, _ in
            CommandPaletteSearchResults()
        }

        viewModel.show()
        viewModel.query = "nothing"
        viewModel.refresh()
        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertTrue(viewModel.sections.isEmpty)
        XCTAssertTrue(viewModel.visibleItems.isEmpty)
    }

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
        viewModel.setAvailableSearchCategories(CommandPaletteSearchCategory.footerOrder(includeThisPlaylist: true), refreshIfFilterInvalidated: false)
        viewModel.searchCategoryFilter = .thisPlaylist
        viewModel.setAvailableSearchCategories(CommandPaletteSearchCategory.footerOrder(includeThisPlaylist: false), refreshIfFilterInvalidated: false)
        XCTAssertEqual(viewModel.searchCategoryFilter, .tracks)
    }

    func testAugmentationShouldFetchWhenQueryMatchesArtistName() {
        XCTAssertTrue(
            SpotifyPaletteSearchAugmentation.shouldFetchArtistScopedTracks(trimmedUserQuery: "kanye", topArtistName: "Kanye West", primaryTrackCount: 0)
        )
        XCTAssertTrue(
            SpotifyPaletteSearchAugmentation.shouldFetchArtistScopedTracks(trimmedUserQuery: "kanye west", topArtistName: "Kanye West", primaryTrackCount: 0)
        )
        XCTAssertFalse(
            SpotifyPaletteSearchAugmentation.shouldFetchArtistScopedTracks(trimmedUserQuery: "love", topArtistName: "The Beatles", primaryTrackCount: 0)
        )
        XCTAssertFalse(
            SpotifyPaletteSearchAugmentation.shouldFetchArtistScopedTracks(trimmedUserQuery: "kanye", topArtistName: "Kanye West", primaryTrackCount: 6)
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

    func testExecuteSelectionPinningRunsPinAction() async {
        let vm = CommandPaletteViewModel()
        var didPin = false
        let item = CommandPaletteItem(
            id: "track-x",
            title: "T",
            subtitle: "S",
            iconSystemName: "music.note",
            section: .tracks,
            keywords: [],
            pinAction: { didPin = true },
            unpinAction: nil,
            action: {}
        )
        vm.testingReplaceSections([(.tracks, [item])])
        vm.selectedIndex = 0
        await vm.executeSelectionPinning()
        XCTAssertTrue(didPin)
    }

    func testCanPinSelectedItemFalseWhenNoPinAction() {
        let vm = CommandPaletteViewModel()
        let item = CommandPaletteItem(
            id: "cmd",
            title: "Cmd",
            subtitle: nil,
            iconSystemName: "gear",
            section: .commands,
            keywords: [],
            action: {}
        )
        vm.testingReplaceSections([(.commands, [item])])
        vm.selectedIndex = 0
        XCTAssertFalse(vm.canPinSelectedItem)
    }

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

    func testHandleKeyEventDropsAutoRepeatedHotkey() async {
        let manager = CommandPaletteManager()
        manager.isSignedIn = true
        var invocations = 0
        manager.previousTrack = { invocations += 1 }

        // shift-cmd-left default binding from CommandPaletteCommandCatalog. The
        // keymap parser normalizes "left" to NSLeftArrowFunctionKey, so the
        // synthetic event must carry that character or `CommandShortcut(event:)`
        // returns nil and the keymap dispatch is skipped.
        let modifiers: NSEvent.ModifierFlags = [.shift, .command]
        let leftArrowCharacter = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        guard let firstPress = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: leftArrowCharacter,
            charactersIgnoringModifiers: leftArrowCharacter,
            isARepeat: false,
            keyCode: 123
        ),
        let repeatedPress = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: leftArrowCharacter,
            charactersIgnoringModifiers: leftArrowCharacter,
            isARepeat: true,
            keyCode: 123
        ) else {
            return XCTFail("Could not synthesize NSEvent for shift-cmd-left.")
        }

        XCTAssertTrue(manager.handleKeyEvent(firstPress), "First press must be consumed by the keymap.")
        for _ in 0..<8 {
            XCTAssertFalse(
                manager.handleKeyEvent(repeatedPress),
                "Auto-repeat events for a transport hotkey must not be consumed; they must fall through to AppKit."
            )
        }

        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(
            invocations,
            1,
            "Only the initial (non-repeat) shift-cmd-left should reach previousTrack; auto-repeats must be dropped."
        )
    }

    func testHandleKeyEventRunsDuplicateMatchedCommandOnlyOnce() {
        let url = makeTempSettingsURL()
        let settingsStore = SpotiglassSettingsStore(fileURL: url)
        let keymapStore = CommandPaletteKeymapStore(settingsStore: settingsStore)
        keymapStore.editorText = """
        {
          "bindings": [
            { "keystrokes": ["cmd-k"], "command": "\(CommandPaletteCommandID.openPalette)", "when": "always" },
            { "keystrokes": ["cmd-k"], "command": "\(CommandPaletteCommandID.openPalette)", "when": "always" }
          ]
        }
        """
        keymapStore.applyEditorText()

        let manager = CommandPaletteManager(keymapStore: keymapStore)
        manager.viewModel.hide()

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "k",
            charactersIgnoringModifiers: "k",
            isARepeat: false,
            keyCode: 40
        ) else {
            return XCTFail("Could not synthesize NSEvent for cmd-k.")
        }

        XCTAssertTrue(manager.handleKeyEvent(event))
        XCTAssertTrue(manager.viewModel.isPresented)
    }
}
