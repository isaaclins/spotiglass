import XCTest
@testable import Spotiglass

@MainActor
final class CommandPaletteTests: XCTestCase {
    func testShortcutParsingSupportsModifiers() throws {
        let shortcut = try CommandShortcut(keystroke: "shift-cmd-k")
        XCTAssertEqual(shortcut.key, "k")
        XCTAssertTrue(shortcut.modifiers.contains(.command))
        XCTAssertTrue(shortcut.modifiers.contains(.shift))
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

    func testScopeParseAtPrefixYieldsArtistsScope() {
        let bare = CommandPaletteScope.parse("@")
        XCTAssertEqual(bare.scope, .artists)
        XCTAssertEqual(bare.query, "")

        let withQuery = CommandPaletteScope.parse("@malcolm")
        XCTAssertEqual(withQuery.scope, .artists)
        XCTAssertEqual(withQuery.query, "malcolm")
    }

    // MARK: - Sectioned view-model state

    func testSongsScopeEmitsOnlySongsSection() async {
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
        viewModel.searchProvider = { _ in
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
        viewModel.query = "midnight"
        viewModel.refresh()
        try? await Task.sleep(for: .milliseconds(320))

        XCTAssertEqual(viewModel.sections.count, 1)
        XCTAssertEqual(viewModel.sections.first?.section, .tracks)
        XCTAssertEqual(viewModel.sections.first?.items.map(\.id), ["track-1"])
        XCTAssertEqual(viewModel.visibleItems.map(\.id), ["track-1"])
    }

    func testArtistsScopeEmitsOnlyArtistsSection() async {
        let viewModel = CommandPaletteViewModel()
        viewModel.searchProvider = { _ in
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
        viewModel.query = "@m83"
        viewModel.refresh()
        try? await Task.sleep(for: .milliseconds(320))

        XCTAssertEqual(viewModel.sections.count, 1)
        XCTAssertEqual(viewModel.sections.first?.section, .artists)
        XCTAssertEqual(viewModel.sections.first?.items.map(\.id), ["artist-1"])
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
        viewModel.searchProvider = { _ in
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
        try? await Task.sleep(for: .milliseconds(320))

        XCTAssertEqual(viewModel.sections.count, 1)
        XCTAssertEqual(viewModel.sections.first?.section, .commands)
        XCTAssertEqual(Set(viewModel.sections.first?.items.map(\.id) ?? []), ["cmd-1", "cmd-2"])
    }

    func testNoResultsLeavesSectionsEmptyForNonEmptyQuery() async {
        let viewModel = CommandPaletteViewModel()
        viewModel.searchProvider = { _ in
            CommandPaletteSearchResults()
        }

        viewModel.show()
        viewModel.query = "nothing"
        viewModel.refresh()
        try? await Task.sleep(for: .milliseconds(320))

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
        try? await Task.sleep(for: .milliseconds(320))

        XCTAssertEqual(viewModel.visibleItems.count, 1)
        await viewModel.executeSelection()
        XCTAssertTrue(viewModel.isPresented, "Items with keepsPaletteOpen should not dismiss the palette")
    }
}
