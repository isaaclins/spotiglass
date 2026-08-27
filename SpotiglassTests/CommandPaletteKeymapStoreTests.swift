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

    /// The key monitor consumes a matched event before AppKit reaches the menu,
    /// so binding a menu-owned chord would kill a menu item that keeps showing
    /// it. Those chords are refused, not silently accepted (#129).
    func testSetBindingRefusesChordsOwnedByMenuItems() throws {
        let url = makeCommandPaletteTestsTempSettingsURL()
        let settingsStore = SpotiglassSettingsStore(fileURL: url)
        let store = CommandPaletteKeymapStore(settingsStore: settingsStore)

        let original = store.primaryShortcut(for: CommandPaletteCommandID.openSettings)
        for reservation in CommandPaletteReservedShortcuts.all {
            let shortcut = try CommandShortcut(keystroke: reservation.keystroke)
            XCTAssertThrowsError(
                try store.setBinding(
                    commandID: CommandPaletteCommandID.openSettings,
                    shortcut: shortcut,
                    replaceConflicting: false
                ),
                "\(reservation.keystroke) is owned by a menu item and must be refused"
            ) { error in
                XCTAssertEqual(
                    error as? KeymapConflictError,
                    .reservedByMenuItem(
                        menuItemTitle: SpotiglassL10n.string(reservation.menuTitleKey)
                    )
                )
            }
            XCTAssertEqual(
                store.primaryShortcut(for: CommandPaletteCommandID.openSettings),
                original,
                "a refused binding must leave the existing one alone"
            )
        }

        // Replacing does not get to override a menu item either.
        let shuffle = try CommandShortcut(keystroke: "alt-cmd-s")
        XCTAssertThrowsError(
            try store.setBinding(
                commandID: CommandPaletteCommandID.openSettings,
                shortcut: shuffle,
                replaceConflicting: true
            )
        )
    }

    /// Command-K is a rebindable keymap default, so it must not also be listed
    /// as menu-owned: the palette's menu item derives its key equivalent from
    /// the keymap now (#131).
    func testCommandKIsNotReservedBecauseThePaletteItemFollowsTheKeymap() throws {
        let commandK = try CommandShortcut(keystroke: "cmd-k")
        XCTAssertNil(CommandPaletteReservedShortcuts.reservingMenuItem(for: commandK))

        let url = makeCommandPaletteTestsTempSettingsURL()
        let settingsStore = SpotiglassSettingsStore(fileURL: url)
        let store = CommandPaletteKeymapStore(settingsStore: settingsStore)
        XCTAssertNotNil(store.menuShortcut(for: CommandPaletteCommandID.openPalette))

        let rebound = try CommandShortcut(keystroke: "ctrl-shift-p")
        try store.setBinding(
            commandID: CommandPaletteCommandID.openPalette,
            shortcut: rebound,
            replaceConflicting: true
        )
        XCTAssertEqual(store.primaryShortcut(for: CommandPaletteCommandID.openPalette), rebound)
    }

    func testApplyEditorTextMapsMalformedJSONToLocalizedMessage() throws {
        let url = makeCommandPaletteTestsTempSettingsURL()
        let settingsStore = SpotiglassSettingsStore(fileURL: url)
        let store = CommandPaletteKeymapStore(settingsStore: settingsStore)
        let previousL10nStore = SpotiglassL10n.settingsStore
        SpotiglassL10n.settingsStore = settingsStore
        defer { SpotiglassL10n.settingsStore = previousL10nStore }

        store.editorText = "{not valid JSON"
        store.applyEditorText()

        XCTAssertEqual(
            store.lastError,
            SpotiglassL10n.format(
                "keymap.error.invalidJSON",
                SpotiglassL10n.string("palette.settings.advanced")
            )
        )
        XCTAssertFalse(store.lastError?.contains("dataCorrupted") == true)
        XCTAssertFalse(store.lastError?.contains("not valid JSON") == true)
    }

    func testApplyEditorTextNamesMissingValueAndJSONLocation() throws {
        let url = makeCommandPaletteTestsTempSettingsURL()
        let settingsStore = SpotiglassSettingsStore(fileURL: url)
        let store = CommandPaletteKeymapStore(settingsStore: settingsStore)
        let previousL10nStore = SpotiglassL10n.settingsStore
        SpotiglassL10n.settingsStore = settingsStore
        defer { SpotiglassL10n.settingsStore = previousL10nStore }

        store.editorText = #"{"bindings":[{"keystrokes":["cmd-k"]}]}"#
        store.applyEditorText()

        let source = SpotiglassL10n.string("palette.settings.advanced")
        let location = SpotiglassL10n.format("keymap.error.location", source, "bindings[0].command")
        XCTAssertEqual(
            store.lastError,
            SpotiglassL10n.format("keymap.error.missingValue", location)
        )
    }

    func testInvalidStoredKeymapUsesLocalizedRecoveryMessage() throws {
        let url = makeCommandPaletteTestsTempSettingsURL()
        var file = SpotiglassSettingsStore.bootstrapDefaults()
        file.keybinds = [
            CommandPaletteKeyBinding(
                keystrokes: ["cmd-unknown"],
                command: "custom.command",
                when: .always,
                args: nil
            )
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(file).write(to: url)

        let settingsStore = SpotiglassSettingsStore(fileURL: url)
        let previousL10nStore = SpotiglassL10n.settingsStore
        SpotiglassL10n.settingsStore = settingsStore
        defer { SpotiglassL10n.settingsStore = previousL10nStore }
        let store = CommandPaletteKeymapStore(settingsStore: settingsStore)

        let detail = SpotiglassL10n.format("keymap.error.unsupportedToken", "unknown")
        XCTAssertEqual(
            store.lastError,
            SpotiglassL10n.format("keymap.error.invalidStored", url.path, detail)
        )
        XCTAssertFalse(store.lastError?.contains("unsupportedToken") == true)
        XCTAssertNotNil(store.primaryShortcut(for: CommandPaletteCommandID.openPalette))
    }

    func testReloadFromDiskDoesNotExposeRawSettingsDecoderError() throws {
        let url = makeCommandPaletteTestsTempSettingsURL()
        let settingsStore = SpotiglassSettingsStore(fileURL: url)
        let store = CommandPaletteKeymapStore(settingsStore: settingsStore)
        let previousL10nStore = SpotiglassL10n.settingsStore
        SpotiglassL10n.settingsStore = settingsStore
        defer { SpotiglassL10n.settingsStore = previousL10nStore }

        try "{not valid JSON".write(to: url, atomically: true, encoding: .utf8)
        store.reloadFromDisk()

        XCTAssertEqual(
            store.lastError,
            SpotiglassL10n.format("keymap.error.reloadFailed", url.path)
        )
        XCTAssertFalse(store.lastError?.contains("dataCorrupted") == true)
    }
}
