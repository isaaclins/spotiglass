import AppKit
import XCTest
@testable import Spotiglass

@MainActor
final class CommandPaletteKeymapStoreTests: XCTestCase {
    func testSetBindingPersistsAndClears() throws {
        let url = makeCommandPaletteTestsTempSettingsURL()
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
        let url = makeCommandPaletteTestsTempSettingsURL()
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

}
