import AppKit
import XCTest
@testable import Spotiglass

@MainActor
final class CommandPaletteModelsTests: XCTestCase {
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
}
