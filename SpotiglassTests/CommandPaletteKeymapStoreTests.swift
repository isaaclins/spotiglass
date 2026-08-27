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

    // MARK: - Multiple rows per command (#279)

    /// The runtime dispatches by filtering candidate rows on `when`, so a command may
    /// carry several context-scoped rows. Applying that JSON must round-trip all of
    /// them (and their `args`) instead of keeping only the first row per command.
    func testApplyEditorTextPreservesEveryContextRowForOneCommand() throws {
        let url = makeCommandPaletteTestsTempSettingsURL()
        let settingsStore = SpotiglassSettingsStore(fileURL: url)
        let store = CommandPaletteKeymapStore(settingsStore: settingsStore)

        store.editorText = """
        {
          "bindings": [
            { "keystrokes": ["cmd-k"], "command": "palette.open", "when": "always" },
            { "keystrokes": ["ctrl-p"], "command": "palette.open", "when": "palette_open",
              "args": { "mode": "commands" } }
          ]
        }
        """
        store.applyEditorText()
        XCTAssertNil(store.lastError)

        let rows = try JSONDecoder()
            .decode(CommandPaletteKeymapFile.self, from: Data(store.editorText.utf8))
            .bindings
            .filter { $0.command == CommandPaletteCommandID.openPalette }
        XCTAssertEqual(rows.count, 2, "both accepted rows must survive normalization")
        XCTAssertEqual(rows.map(\.when), [.always, .paletteOpen])
        XCTAssertEqual(rows[1].args?["mode"], .string("commands"))

        let onDisk = try JSONDecoder().decode(SpotiglassSettingsFile.self, from: Data(contentsOf: url))
        XCTAssertEqual(onDisk.keybinds.filter { $0.command == CommandPaletteCommandID.openPalette }.count, 2)

        // Both rows are indexed, and each only fires in its own context.
        let ctrlP = try CommandShortcut(keystroke: "ctrl-p")
        XCTAssertEqual(store.bindings[ctrlP]?.count, 1)
        XCTAssertEqual(store.bindings[try CommandShortcut(keystroke: "cmd-k")]?.count, 1)
    }

    /// Rebinding from the settings GUI edits the command's primary row only; the
    /// extra context row and its args stay on disk (#279).
    func testSetBindingKeepsAdditionalContextRowForSameCommand() throws {
        let url = makeCommandPaletteTestsTempSettingsURL()
        let settingsStore = SpotiglassSettingsStore(fileURL: url)
        let store = CommandPaletteKeymapStore(settingsStore: settingsStore)

        store.editorText = """
        {
          "bindings": [
            { "keystrokes": ["cmd-,"], "command": "app.openSettings", "when": "always" },
            { "keystrokes": ["ctrl-,"], "command": "app.openSettings", "when": "palette_open",
              "args": { "tab": "keymap" } }
          ]
        }
        """
        store.applyEditorText()
        XCTAssertNil(store.lastError)

        let rebound = try CommandShortcut(keystroke: "shift-cmd-9")
        try store.setBinding(
            commandID: CommandPaletteCommandID.openSettings,
            shortcut: rebound,
            replaceConflicting: false
        )

        let rows = try JSONDecoder()
            .decode(CommandPaletteKeymapFile.self, from: Data(store.editorText.utf8))
            .bindings
            .filter { $0.command == CommandPaletteCommandID.openSettings }
        XCTAssertEqual(rows.count, 2, "the secondary context row must not be dropped by a rebind")
        XCTAssertEqual(rows[0].keystrokes, ["shift-cmd-9"])
        XCTAssertEqual(rows[1].keystrokes, ["ctrl-,"])
        XCTAssertEqual(rows[1].when, .paletteOpen)
        XCTAssertEqual(rows[1].args?["tab"], .string("keymap"))
    }

    /// Clearing from the one-row settings UI is the explicit "unbind this command"
    /// action, so it removes every context row for that command.
    func testClearBindingRemovesEveryContextRowForThatCommand() throws {
        let url = makeCommandPaletteTestsTempSettingsURL()
        let settingsStore = SpotiglassSettingsStore(fileURL: url)
        let store = CommandPaletteKeymapStore(settingsStore: settingsStore)

        store.editorText = """
        {
          "bindings": [
            { "keystrokes": ["cmd-,"], "command": "app.openSettings", "when": "always" },
            { "keystrokes": ["ctrl-,"], "command": "app.openSettings", "when": "palette_open" }
          ]
        }
        """
        store.applyEditorText()
        try store.clearBinding(commandID: CommandPaletteCommandID.openSettings)

        let rows = try JSONDecoder()
            .decode(CommandPaletteKeymapFile.self, from: Data(store.editorText.utf8))
            .bindings
            .filter { $0.command == CommandPaletteCommandID.openSettings }
        XCTAssertTrue(rows.isEmpty)
    }

    /// Validation runs before the settings store writes, so a row with an
    /// unsupported keystroke leaves the previous keymap on disk intact (#279).
    func testApplyEditorTextDoesNotPersistWhenARowFailsValidation() throws {
        let url = makeCommandPaletteTestsTempSettingsURL()
        let settingsStore = SpotiglassSettingsStore(fileURL: url)
        let store = CommandPaletteKeymapStore(settingsStore: settingsStore)
        let before = try JSONDecoder().decode(SpotiglassSettingsFile.self, from: Data(contentsOf: url)).keybinds

        store.editorText = """
        {
          "bindings": [
            { "keystrokes": ["cmd-k"], "command": "palette.open", "when": "always" },
            { "keystrokes": ["cmd-notakey"], "command": "palette.open", "when": "palette_open" }
          ]
        }
        """
        store.applyEditorText()

        XCTAssertNotNil(store.lastError, "an invalid keystroke must be reported")
        let after = try JSONDecoder().decode(SpotiglassSettingsFile.self, from: Data(contentsOf: url)).keybinds
        XCTAssertEqual(after, before, "nothing may be written until every row validates")
    }

    // MARK: - Localized keymap errors (#287)

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
