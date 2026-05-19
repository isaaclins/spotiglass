import AppKit
import XCTest
@testable import Spotiglass

@MainActor
final class CommandPaletteManagerKeyEventTests: XCTestCase {
    private func keyDown(
        keyCode: UInt16,
        characters: String = "",
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    func testPaletteOpenEscapeHidesAndConsumes() {
        let manager = CommandPaletteManager()
        manager.viewModel.show()
        XCTAssertTrue(manager.handleKeyEvent(keyDown(keyCode: 53)))
        XCTAssertFalse(manager.viewModel.isPresented)
    }

    func testPaletteOpenArrowKeysMoveSelection() {
        let manager = CommandPaletteManager()
        manager.viewModel.show()
        manager.viewModel.testingReplaceSections([
            (.commands, [
                CommandPaletteItem(id: "a", title: "A", subtitle: nil, iconSystemName: "command", section: .commands, keywords: [], action: {}),
                CommandPaletteItem(id: "b", title: "B", subtitle: nil, iconSystemName: "command", section: .commands, keywords: [], action: {}),
            ]),
        ])
        let start = manager.viewModel.selectedIndex
        XCTAssertTrue(manager.handleKeyEvent(keyDown(keyCode: 125)))
        XCTAssertEqual(manager.viewModel.selectedIndex, start + 1)
        XCTAssertTrue(manager.handleKeyEvent(keyDown(keyCode: 126)))
        XCTAssertEqual(manager.viewModel.selectedIndex, start)
    }

    func testTabCyclesSearchCategoryWhenNotCommandsScope() {
        let manager = CommandPaletteManager()
        manager.viewModel.show()
        manager.viewModel.query = "query"
        let before = manager.viewModel.searchCategoryFilter
        XCTAssertTrue(manager.handleKeyEvent(keyDown(keyCode: 48)))
        XCTAssertNotEqual(manager.viewModel.searchCategoryFilter, before)
    }

    func testDismissLyricsOverlayConsumesEscape() {
        let manager = CommandPaletteManager()
        manager.dismissLyricsOverlayIfPresented = { true }
        XCTAssertTrue(manager.handleKeyEvent(keyDown(keyCode: 53)))
    }

    func testIsRecordingHotkeyBypassesKeymap() throws {
        let url = makeCommandPaletteTestsTempSettingsURL()
        let settings = SpotiglassSettingsStore(fileURL: url)
        let keymap = CommandPaletteKeymapStore(settingsStore: settings)
        let manager = CommandPaletteManager(keymapStore: keymap)
        manager.isSignedIn = true
        manager.isRecordingHotkey = true
        try keymap.setBinding(
            commandID: CommandPaletteCommandID.openPalette,
            shortcut: try CommandShortcut(keystroke: "cmd-k"),
            replaceConflicting: true
        )
        XCTAssertFalse(manager.handleKeyEvent(keyDown(keyCode: 40, characters: "k", modifiers: [.command])))
    }

    func testAutoRepeatDoesNotFireCommands() throws {
        let url = makeCommandPaletteTestsTempSettingsURL()
        let settings = SpotiglassSettingsStore(fileURL: url)
        let keymap = CommandPaletteKeymapStore(settingsStore: settings)
        let manager = CommandPaletteManager(keymapStore: keymap)
        manager.isSignedIn = true
        try keymap.setBinding(
            commandID: CommandPaletteCommandID.toggleLyrics,
            shortcut: try CommandShortcut(keystroke: "cmd-l"),
            replaceConflicting: true
        )
        var toggled = 0
        manager.toggleLyrics = { toggled += 1 }
        let repeatEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "l",
            charactersIgnoringModifiers: "l",
            isARepeat: true,
            keyCode: 37
        )!
        XCTAssertFalse(manager.handleKeyEvent(repeatEvent))
        XCTAssertEqual(toggled, 0)
    }

    func testPlaybackTogglePrerequisiteBlocksBinding() throws {
        let url = makeCommandPaletteTestsTempSettingsURL()
        let settings = SpotiglassSettingsStore(fileURL: url)
        let keymap = CommandPaletteKeymapStore(settingsStore: settings)
        let manager = CommandPaletteManager(keymapStore: keymap)
        manager.isSignedIn = true
        manager.playbackTogglePrerequisite = { false }
        try keymap.setBinding(
            commandID: CommandPaletteCommandID.togglePlayback,
            shortcut: try CommandShortcut(keystroke: "cmd-p"),
            replaceConflicting: true
        )
        var toggled = false
        manager.togglePlayback = { toggled = true }
        XCTAssertFalse(manager.handleKeyEvent(keyDown(keyCode: 35, characters: "p", modifiers: [.command])))
        XCTAssertFalse(toggled)
    }

    func testExecuteWiresPlaybackAndNavigationHandlers() async {
        let manager = CommandPaletteManager()
        let toggle = expectation(description: "toggle")
        manager.togglePlayback = { toggle.fulfill() }
        manager.isSignedIn = true
        manager.execute(commandID: CommandPaletteCommandID.togglePlayback)
        await fulfillment(of: [toggle], timeout: 2)

        let openPlaylist = expectation(description: "playlist")
        manager.openPlaylist = { id in
            XCTAssertEqual(id, "plist-1")
            openPlaylist.fulfill()
        }
        manager.execute(commandID: "navigation.playlist.open", args: ["playlistID": .string("plist-1")])
        await fulfillment(of: [openPlaylist], timeout: 2)
    }

    func testBaseItemsRespectSignedInFlag() {
        let manager = CommandPaletteManager()
        manager.isSignedIn = false
        let signedOutCount = manager.viewModel.staticItemsProvider().count
        manager.isSignedIn = true
        let signedInCount = manager.viewModel.staticItemsProvider().count
        XCTAssertGreaterThanOrEqual(signedInCount, signedOutCount)
    }

    func testExecuteRefreshAndPrefetchHooks() async {
        let manager = CommandPaletteManager()
        let refresh = expectation(description: "refresh")
        manager.unifiedRefresh = { refresh.fulfill() }
        manager.execute(commandID: CommandPaletteCommandID.refreshPlaylists)
        await fulfillment(of: [refresh], timeout: 2)

        var prefetched = false
        manager.prefetchAllPlaylists = { prefetched = true }
        manager.execute(commandID: CommandPaletteCommandID.prefetchAllPlaylists)
        XCTAssertTrue(prefetched)
    }
}
