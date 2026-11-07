import AppKit
import XCTest
@testable import Spotiglass

@MainActor
final class CommandPaletteModelsTests: XCTestCase {
    func testFooterOrderLeadsWithAllAsSmartDefault() {
        XCTAssertEqual(
            CommandPaletteSearchCategory.footerOrder(includeThisPlaylist: true),
            [.all, .tracks, .artists, .thisPlaylist, .myPlaylists]
        )
        XCTAssertEqual(
            CommandPaletteSearchCategory.footerOrder(includeThisPlaylist: false),
            [.all, .tracks, .artists, .myPlaylists]
        )
    }

    func testThisPlaylistSectionUsesHereDisplayLabel() {
        XCTAssertEqual(
            CommandPaletteSection.thisPlaylist.displayLabel,
            SpotiglassL10n.string("palette.section.thisPlaylist")
        )
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

    // MARK: - Service wording and ranking (#397)

    /// ">spot" listed "Open Settings" first, because its subtitle starts with "Spotiglass",
    /// above "Switch to Spotify", whose title has a word starting with "spot".
    func testANameMatchRanksAboveASubtitleMatch() {
        let settings = CommandPaletteItem(
            id: "settings", title: "Open Settings", subtitle: "Spotiglass preferences and shortcuts",
            iconSystemName: "gearshape", section: .commands, keywords: [], action: {}
        )
        let switchToSpotify = CommandPaletteItem(
            id: "switch", title: "Switch to Spotify", subtitle: "Show your Spotify library",
            iconSystemName: "arrow.left.arrow.right", section: .commands, keywords: [], action: {}
        )
        XCTAssertLessThan(switchToSpotify.score(for: "spot"), settings.score(for: "spot"))
        // A subtitle match still matches.
        XCTAssertLessThan(settings.score(for: "preferences"), 100)
        // Exact and prefix title matches keep their place.
        XCTAssertEqual(switchToSpotify.score(for: "switch to spotify"), 0)
        XCTAssertEqual(switchToSpotify.score(for: "swi"), 1)
    }

    /// The palette said "Search Spotify" while it searched Apple Music.
    func testSearchWordingNamesTheServiceOnScreen() {
        let previous = MusicServiceSelection.current
        defer { MusicServiceSelection.current = previous }

        MusicServiceSelection.current = .appleMusic
        XCTAssertEqual(CommandPaletteScopePresentation.searchPlaceholder(scope: .songs, category: .all), "Search Apple Music")
        XCTAssertEqual(SpotiglassL10n.format("palette.searching", MusicServiceSelection.current.displayName), "Searching Apple Music")
        let openSearch = CommandPaletteCommandCatalog.editable.first { $0.commandID == CommandPaletteCommandID.openSearch }
        XCTAssertEqual(openSearch?.subtitle, "Search Apple Music for tracks, albums, artists and playlists")

        MusicServiceSelection.current = .spotify
        XCTAssertEqual(CommandPaletteScopePresentation.searchPlaceholder(scope: .songs, category: .all), "Search Spotify")
        XCTAssertEqual(openSearch?.subtitle, "Search Spotify for tracks, albums, artists and playlists")
    }
}
