import AppKit
import SwiftUI
import XCTest
@testable import Spotiglass

/// The pop-out lyrics window (#439).
@MainActor
final class LyricsPopOutTests: XCTestCase {
    private func makeManager() -> (CommandPaletteManager, CommandPaletteKeymapStore) {
        let settings = SpotiglassSettingsStore(fileURL: makeCommandPaletteTestsTempSettingsURL())
        let keymap = CommandPaletteKeymapStore(settingsStore: settings)
        let manager = CommandPaletteManager(keymapStore: keymap)
        manager.isSignedIn = true
        return (manager, keymap)
    }

    private func makeWindow() -> OffscreenTestWindow {
        AppKitTestSupport.activateAppIfNeeded()
        let window = OffscreenTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return window
    }

    private func keyDown(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags = [],
        window: NSWindow
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    // MARK: Opening it

    func testPopOutHasAPaletteRowAMenuChordAndARebindableDefault() throws {
        let spec = try XCTUnwrap(
            CommandPaletteCommandCatalog.editable.first { $0.commandID == CommandPaletteCommandID.popOutLyrics }
        )
        XCTAssertEqual(spec.defaultKeystroke, "shift-alt-cmd-l")
        XCTAssertTrue(CommandPaletteCommandCatalog.defaultKeymapJSON.contains(CommandPaletteCommandID.popOutLyrics))

        let (manager, keymap) = makeManager()
        let shortcut = try XCTUnwrap(keymap.menuShortcut(for: CommandPaletteCommandID.popOutLyrics))
        XCTAssertEqual(shortcut.key.character, "l")
        XCTAssertEqual(shortcut.modifiers, [.command, .option, .shift])

        // Listed only once something can open the window.
        XCTAssertFalse(manager.viewModel.staticItemsProvider().contains { $0.id == CommandPaletteCommandID.popOutLyrics })
        manager.popOutLyrics = {}
        XCTAssertTrue(manager.viewModel.staticItemsProvider().contains { $0.id == CommandPaletteCommandID.popOutLyrics })
    }

    func testThePopOutChordOpensTheWindow() {
        let (manager, _) = makeManager()
        var opened = 0
        manager.popOutLyrics = { opened += 1 }
        let window = makeWindow()
        defer { AppKitTestSupport.closeWindowSafely(window) }

        XCTAssertTrue(
            manager.handleKeyEvent(
                keyDown(keyCode: 37, characters: "l", modifiers: [.command, .option, .shift], window: window)
            )
        )
        XCTAssertEqual(opened, 1)
    }

    /// Choosing it in the palette closes the palette: the window it opens is where to look.
    func testChoosingItInThePaletteClosesThePalette() {
        let (manager, _) = makeManager()
        var opened = 0
        manager.popOutLyrics = { opened += 1 }
        manager.viewModel.show()
        manager.execute(commandID: CommandPaletteCommandID.popOutLyrics)
        XCTAssertEqual(opened, 1)
        XCTAssertFalse(manager.viewModel.isPresented)
    }

    /// Signing out or switching service detaches the browser's commands; the pop-out shows the
    /// app-wide player, so its command stays.
    func testDetachKeepsThePopOutCommand() {
        let (manager, _) = makeManager()
        var opened = 0
        manager.popOutLyrics = { opened += 1 }
        manager.detach()
        manager.execute(commandID: CommandPaletteCommandID.popOutLyrics)
        XCTAssertEqual(opened, 1)
    }

    // MARK: Keys pressed in the pop-out

    /// The key monitor is app-wide and runs the main window's commands. Escape in the pop-out
    /// used to reach the main window and close its lyrics view (and its palette).
    func testEscapeInThePopOutLeavesTheMainWindowAlone() {
        let (manager, _) = makeManager()
        var dismissedLyrics = false
        manager.dismissLyricsOverlayIfPresented = {
            dismissedLyrics = true
            return true
        }
        manager.viewModel.show()
        let popOut = makeWindow()
        LyricsPopOutWindow.adopt(popOut)
        defer { AppKitTestSupport.closeWindowSafely(popOut) }

        XCTAssertFalse(manager.handleKeyEvent(keyDown(keyCode: 53, characters: "\u{1b}", window: popOut)))
        XCTAssertFalse(dismissedLyrics)
        XCTAssertTrue(manager.viewModel.isPresented)

        // The same key in a main window still closes the palette.
        let main = makeWindow()
        defer { AppKitTestSupport.closeWindowSafely(main) }
        XCTAssertTrue(manager.handleKeyEvent(keyDown(keyCode: 53, characters: "\u{1b}", window: main)))
        XCTAssertFalse(manager.viewModel.isPresented)
    }

    func testThePopOutRunsOnlyItsTransportKeys() {
        let (manager, _) = makeManager()
        let toggled = expectation(description: "Space plays or pauses")
        manager.togglePlayback = { toggled.fulfill() }
        let popOut = makeWindow()
        LyricsPopOutWindow.adopt(popOut)
        defer { AppKitTestSupport.closeWindowSafely(popOut) }

        XCTAssertTrue(manager.handleKeyEvent(keyDown(keyCode: 49, characters: " ", window: popOut)))
        wait(for: [toggled], timeout: 1)

        // ⌘K would open the palette in the main window, out of sight behind this one.
        XCTAssertFalse(manager.handleKeyEvent(keyDown(keyCode: 40, characters: "k", modifiers: [.command], window: popOut)))
        XCTAssertFalse(manager.viewModel.isPresented)
    }

    // MARK: The window

    func testPinKeepsTheWindowAboveOtherAppsAndUnpinMakesItOrdinary() {
        let window = makeWindow()
        defer { AppKitTestSupport.closeWindowSafely(window) }

        LyricsPopOutWindow.apply(isPinned: true, to: window)
        XCTAssertEqual(window.level, .floating)
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))

        LyricsPopOutWindow.apply(isPinned: false, to: window)
        XCTAssertEqual(window.level, .normal)
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    func testTheWindowRemembersItsFrameAndIsPinnedByDefault() {
        let window = makeWindow()
        defer { AppKitTestSupport.closeWindowSafely(window) }
        LyricsPopOutWindow.adopt(window)
        XCTAssertEqual(window.frameAutosaveName, LyricsPopOutWindow.frameAutosaveName)
        XCTAssertTrue(LyricsPopOutWindow.isPopOut(window))
        XCTAssertTrue(LyricsPopOutWindow.isPinnedByDefault)
    }

    func testLayoutShrinksToAStripAndDropsSkipButtonsWhenNarrow() {
        XCTAssertEqual(LyricsPopOutLayout.layout(for: LyricsPopOutWindow.defaultSize), .full)
        XCTAssertEqual(LyricsPopOutLayout.layout(for: LyricsPopOutWindow.minimumSize), .strip)
        XCTAssertEqual(LyricsPopOutLayout.layout(for: CGSize(width: 600, height: 120)), .strip)
        XCTAssertTrue(LyricsPopOutLayout.showsSkipButtons(width: LyricsPopOutWindow.defaultSize.width))
        XCTAssertFalse(LyricsPopOutLayout.showsSkipButtons(width: LyricsPopOutWindow.minimumSize.width))
    }

    // MARK: The strip's line

    func testStripShowsTheLineBeingSungAndFallsBackToTheTitle() {
        let lines = [
            SyncedLyricLine(id: 0, startTimeMs: 0, words: "First line"),
            SyncedLyricLine(id: 1, startTimeMs: 5_000, words: " "),
            SyncedLyricLine(id: 2, startTimeMs: 9_000, words: "Third line"),
        ]
        func text(_ phase: ImmersiveLyricsViewModel.Phase, at ms: Int) -> String {
            LyricsPopOutStripText.text(phase: phase, trackName: "Song", trackDurationMs: 60_000, positionMs: ms)
        }
        XCTAssertEqual(text(.ready(.synced(lines)), at: 1_000), "First line")
        XCTAssertEqual(text(.ready(.synced(lines)), at: 10_000), "Third line")
        // A gap in the singing shows the title instead of an empty row.
        XCTAssertEqual(text(.ready(.synced(lines)), at: 6_000), "Song")
        XCTAssertEqual(text(.loading, at: 0), "Song")
        XCTAssertEqual(text(.failed("No lyrics"), at: 0), "Song")
        XCTAssertEqual(text(.ready(.instrumental), at: 0), SpotiglassL10n.string("lyrics.instrumental"))
    }
}
