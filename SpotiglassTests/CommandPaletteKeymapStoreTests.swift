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

    func testCrossContextDuplicateIsAllowedAndReported() throws {
        let url = makeCommandPaletteTestsTempSettingsURL()
        let settingsStore = SpotiglassSettingsStore(fileURL: url)
        let store = CommandPaletteKeymapStore(settingsStore: settingsStore)
        let shared = try CommandShortcut(keystroke: "cmd-return")

        // Search runs while signed in; Pin runs only while the palette is open.
        // Those contexts do not overlap, so the save succeeds, but Settings must
        // still be able to explain why two rows display the same chord.
        try store.setBinding(
            commandID: CommandPaletteCommandID.openSearch,
            shortcut: shared,
            replaceConflicting: false
        )

        XCTAssertEqual(store.primaryShortcut(for: CommandPaletteCommandID.openSearch), shared)
        XCTAssertEqual(
            store.crossContextUsages(
                of: shared,
                excludingCommand: CommandPaletteCommandID.openSearch,
                proposedWhen: .signedIn
            ),
            [
                CommandPaletteShortcutUsage(
                    commandID: CommandPaletteCommandID.pinSelected,
                    context: .paletteOpen
                ),
            ]
        )
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
                    .reservedByMenuItem(menuTitleKey: reservation.menuTitleKey)
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
        XCTAssertNil(CommandPaletteReservedShortcuts.reservingMenuTitleKey(for: commandK))

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

    /// A hand edit that doesn't parse, then the fix and Reload again: the reload error under
    /// the advanced editor goes away with the fixed file instead of staying on screen.
    func testFixedFileClearsTheReloadErrorOnTheNextReload() throws {
        let url = makeCommandPaletteTestsTempSettingsURL()
        let settingsStore = SpotiglassSettingsStore(fileURL: url)
        let store = CommandPaletteKeymapStore(settingsStore: settingsStore)
        let good = try Data(contentsOf: url)

        try Data(#"{"version":2,"keybinds":["#.utf8).write(to: url)
        store.reloadFromDisk()
        XCTAssertNotNil(store.lastError)

        try good.write(to: url)
        store.reloadFromDisk()
        XCTAssertNil(store.lastError)
        XCTAssertNil(settingsStore.lastError)
    }

    /// Ten custom shortcuts and one row this build can't read (a key token from a newer
    /// build): the whole keymap used to fall back to the defaults, and recording one new
    /// shortcut then saved the defaults over every custom row (#597).
    func testUnusableStoredRowDoesNotCostTheOtherCustomShortcuts() throws {
        let url = makeCommandPaletteTestsTempSettingsURL()
        var file = SpotiglassSettingsStore.bootstrapDefaults()
        let custom = CommandPaletteKeyBinding(
            keystrokes: ["shift-cmd-8"],
            command: CommandPaletteCommandID.toggleQueue,
            when: .always,
            args: nil
        )
        let fromNewerBuild = CommandPaletteKeyBinding(
            keystrokes: ["cmd-unknown"],
            command: "custom.command",
            when: .always,
            args: nil
        )
        file.keybinds = [custom, fromNewerBuild]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(file).write(to: url)

        let settingsStore = SpotiglassSettingsStore(fileURL: url)
        let store = CommandPaletteKeymapStore(settingsStore: settingsStore)

        XCTAssertEqual(store.primaryShortcut(for: CommandPaletteCommandID.toggleQueue), try CommandShortcut(keystroke: "shift-cmd-8"))
        XCTAssertEqual(store.unusableRows, [fromNewerBuild])
        XCTAssertNotNil(store.unusableRowsText)
        // One row reads as one, not "1 saved shortcuts".
        for (language, one, other) in [
            ("en", "One saved shortcut", "2 saved shortcuts"),
            ("de", "Ein gespeichertes Tastenkürzel", "2 gespeicherte Tastenkürzel"),
            ("es", "un atajo guardado", "2 atajos guardados"),
        ] {
            let locale = Locale(identifier: language)
            XCTAssertTrue(SpotiglassL10n.format("keymap.unusableRows", locale: locale, 1).contains(one), language)
            XCTAssertTrue(SpotiglassL10n.format("keymap.unusableRows", locale: locale, 2).contains(other), language)
        }

        try store.setBinding(
            commandID: CommandPaletteCommandID.openSettings,
            shortcut: try CommandShortcut(keystroke: "shift-cmd-9"),
            replaceConflicting: false
        )

        let saved = try JSONDecoder().decode(SpotiglassSettingsFile.self, from: try Data(contentsOf: url)).keybinds
        XCTAssertTrue(saved.contains(custom), "the custom shortcut is gone")
        XCTAssertTrue(saved.contains(fromNewerBuild), "the newer build's row is gone")
        XCTAssertTrue(saved.contains { $0.command == CommandPaletteCommandID.openSettings && $0.keystrokes == ["shift-cmd-9"] })
        XCTAssertNotNil(store.unusableRowsText, "the notice stays while the row does")

        try store.clearBinding(commandID: CommandPaletteCommandID.openSettings)
        let afterClear = try JSONDecoder().decode(SpotiglassSettingsFile.self, from: try Data(contentsOf: url)).keybinds
        XCTAssertEqual(afterClear, [custom, fromNewerBuild])
    }

    /// A new row typed into the advanced editor is still checked: only rows that were already
    /// stored unusable pass through.
    func testAdvancedEditorStillRejectsANewUnusableRow() throws {
        let url = makeCommandPaletteTestsTempSettingsURL()
        let settingsStore = SpotiglassSettingsStore(fileURL: url)
        let store = CommandPaletteKeymapStore(settingsStore: settingsStore)
        let before = try Data(contentsOf: url)

        store.editorText = #"{"bindings":[{"keystrokes":["cmd-unknown"],"command":"custom.command","when":"always"}]}"#
        store.applyEditorText()

        XCTAssertNotNil(store.lastError)
        XCTAssertEqual(try Data(contentsOf: url), before)
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
