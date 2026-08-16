import AppKit
import SwiftUI
import XCTest
@testable import Spotiglass

@MainActor
final class MenuKeyEquivalentTests: XCTestCase {
    private func makeStore() -> CommandPaletteKeymapStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpotiglassMenuKeyEquivalent-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
        return CommandPaletteKeymapStore(fileURL: url)
    }

    func testModifierBearingChordBecomesMenuKeyEquivalent() throws {
        let shortcut = try XCTUnwrap(try CommandShortcut(keystroke: "shift-cmd-right").menuKeyboardShortcut)

        XCTAssertEqual(shortcut.key.character, KeyEquivalent.rightArrow.character)
        XCTAssertEqual(shortcut.modifiers, [.command, .shift])
    }

    /// A menu key equivalent is matched before the key reaches the focused view,
    /// so the bare Space binding for Play/Pause must never reach the menu bar.
    func testBareAndShiftOnlyChordsAreRefusedAsMenuKeyEquivalents() throws {
        XCTAssertNil(try CommandShortcut(keystroke: "space").menuKeyboardShortcut)
        XCTAssertNil(try CommandShortcut(keystroke: "shift-return").menuKeyboardShortcut)
        XCTAssertNotNil(try CommandShortcut(keystroke: "ctrl-space").menuKeyboardShortcut)
        XCTAssertNotNil(try CommandShortcut(keystroke: "alt-cmd-q").menuKeyboardShortcut)
    }

    func testDefaultKeymapDrivesTheMenuBarShortcuts() throws {
        let store = makeStore()

        let next = try XCTUnwrap(store.menuShortcut(for: CommandPaletteCommandID.nextTrack))
        XCTAssertEqual(next.key.character, KeyEquivalent.rightArrow.character)
        XCTAssertEqual(next.modifiers, [.command, .shift])

        let queue = try XCTUnwrap(store.menuShortcut(for: CommandPaletteCommandID.toggleQueue))
        XCTAssertEqual(queue.key.character, "q")
        XCTAssertEqual(queue.modifiers, [.command, .option])

        let lyrics = try XCTUnwrap(store.menuShortcut(for: CommandPaletteCommandID.toggleLyrics))
        XCTAssertEqual(lyrics.key.character, "l")
        XCTAssertEqual(lyrics.modifiers, [.command, .option])

        XCTAssertNil(store.menuShortcut(for: CommandPaletteCommandID.togglePlayback))
        XCTAssertNil(store.menuShortcut(for: CommandPaletteCommandID.toggleShuffle))
    }

    /// Rebinding a command in Settings → Keyboard has to move its menu shortcut,
    /// otherwise the menu bar would keep firing the abandoned chord.
    func testRebindingACommandMovesItsMenuShortcut() throws {
        let store = makeStore()
        try store.setBinding(
            commandID: CommandPaletteCommandID.nextTrack,
            shortcut: try CommandShortcut(keystroke: "ctrl-alt-n"),
            replaceConflicting: true
        )

        let rebound = try XCTUnwrap(store.menuShortcut(for: CommandPaletteCommandID.nextTrack))
        XCTAssertEqual(rebound.key.character, "n")
        XCTAssertEqual(rebound.modifiers, [.control, .option])
    }

    func testClearingABindingRemovesTheMenuShortcut() throws {
        let store = makeStore()
        try store.clearBinding(commandID: CommandPaletteCommandID.toggleQueue)

        XCTAssertNil(store.menuShortcut(for: CommandPaletteCommandID.toggleQueue))
    }

    /// The menu bar dispatches through the same manager the palette and the keymap
    /// use, so shuffle and repeat must land on the wired playback closures.
    func testMenuOnlyShuffleAndRepeatDispatchThroughTheManager() {
        let manager = CommandPaletteManager(keymapStore: makeStore())
        var shuffled = 0
        var repeated = 0
        manager.toggleShuffle = { shuffled += 1 }
        manager.cycleRepeat = { repeated += 1 }

        manager.execute(commandID: CommandPaletteCommandID.toggleShuffle)
        manager.execute(commandID: CommandPaletteCommandID.cycleRepeat)

        let expectation = expectation(description: "playback closures ran")
        Task { @MainActor in
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(shuffled, 1)
        XCTAssertEqual(repeated, 1)
    }

    // MARK: - Help menu (#177)

    /// The default Help item was a silent no-op: the bundle declares no
    /// CFBundleHelpBookName, so choosing it did nothing at all. These are the
    /// destinations that replaced it, and a typo in either one would ship a
    /// Help menu that fails exactly as quietly as the old one did.
    @MainActor
    func testHelpMenuPointsAtRealDestinations() {
        XCTAssertEqual(
            SpotiglassMenuCommands.readmeURL.absoluteString,
            "https://github.com/isaaclins/spotiglass#readme"
        )
        XCTAssertEqual(
            SpotiglassMenuCommands.newIssueURL.absoluteString,
            "https://github.com/isaaclins/spotiglass/issues/new"
        )
        for url in [SpotiglassMenuCommands.readmeURL, SpotiglassMenuCommands.newIssueURL] {
            XCTAssertEqual(url.scheme, "https", "help destinations must not be plain http")
            XCTAssertNotNil(url.host, "a hostless URL opens nothing")
        }
    }

}
