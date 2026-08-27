import AppKit
import Combine
import Foundation

/// Editable view of the keybinds slice of `~/.config/spotiglass/settings.json`.
///
/// Storage is delegated to ``SpotiglassSettingsStore`` so that keybinds and other
/// settings share one on-disk file. The public API (``bindings``, ``setBinding``,
/// ``clearBinding``, ``editorText``, ``applyEditorText``, …) is unchanged from the
/// pre-merge keymap store so existing settings UI and event handling keep working.
@MainActor
final class CommandPaletteKeymapStore: ObservableObject {
    @Published private(set) var bindings: [CommandShortcut: [CommandPaletteKeyBinding]] = [:]
    @Published var editorText: String = ""
    @Published var lastError: String?

    let settingsStore: SpotiglassSettingsStore

    var fileURL: URL { settingsStore.fileURL }

    private var settingsCancellable: AnyCancellable?

    init(settingsStore: SpotiglassSettingsStore) {
        self.settingsStore = settingsStore
        applyFromStore(settingsStore.settings.keybinds)
        if settingsStore.lastError != nil {
            lastError = CommandPaletteKeymapErrorPresenter.settingsReloadFailureMessage(source: fileURL.path)
        }
        settingsCancellable = settingsStore.$settings
            .removeDuplicates { $0.keybinds == $1.keybinds }
            .sink { [weak self] file in
                self?.applyFromStore(file.keybinds)
            }
    }

    /// Convenience initializer for tests: spins up a fresh ``SpotiglassSettingsStore``
    /// pointed at `fileURL`. Production code should construct one shared
    /// ``SpotiglassSettingsStore`` and pass it via the designated initializer.
    convenience init(fileManager: FileManager = .default, fileURL: URL? = nil) {
        let store = SpotiglassSettingsStore(fileManager: fileManager, fileURL: fileURL)
        self.init(settingsStore: store)
    }

    // MARK: - Structured editing (Settings GUI)

    /// First shortcut for a catalog command, if any.
    func primaryShortcut(for commandID: String) -> CommandShortcut? {
        guard let list = try? decodedBindingsFromEditor() else { return nil }
        return list.first { $0.command == commandID }
            .flatMap(\.keystrokes.first)
            .flatMap { try? CommandShortcut(keystroke: $0) }
    }

    func setBinding(commandID: String, shortcut: CommandShortcut, replaceConflicting: Bool) throws {
        guard let spec = CommandPaletteCommandCatalog.editable.first(where: { $0.commandID == commandID }) else {
            return
        }
        var list = try decodedBindingsFromEditor()
        // Menu-owned chords are checked first: the key monitor consumes a match
        // before AppKit reaches the menu, so this binding would silently kill a
        // menu item that still shows the chord (#129).
        if let menuItem = CommandPaletteReservedShortcuts.reservingMenuItem(for: shortcut) {
            throw KeymapConflictError.reservedByMenuItem(menuItemTitle: menuItem)
        }
        if let other = Self.conflictingCommandID(
            for: shortcut,
            excludingCommand: commandID,
            proposedWhen: spec.defaultWhen,
            in: list
        ), !replaceConflicting {
            throw KeymapConflictError.conflict(existingCommandID: other)
        }
        if replaceConflicting {
            list.removeAll { existing in
                guard existing.command != commandID else { return false }
                guard Self.bindingContains(shortcut, in: existing) else { return false }
                return CommandPaletteContext.bindingsOverlapInRuntime(existing.when, spec.defaultWhen)
            }
        }
        let token = try shortcut.canonicalToken()
        // The settings GUI shows one row per command, so it edits the command's
        // primary row in place and leaves any additional context-specific rows
        // (and every row's `args`) untouched. Replacing all rows here would
        // silently delete bindings the runtime still dispatches by `when` (#279).
        if let primaryIndex = list.firstIndex(where: { $0.command == commandID }) {
            list[primaryIndex].keystrokes = [token]
            list[primaryIndex].when = spec.defaultWhen
        } else {
            list.append(
                CommandPaletteKeyBinding(
                    keystrokes: [token],
                    command: commandID,
                    when: spec.defaultWhen,
                    args: nil
                )
            )
        }
        try applyNormalizedPersisting(list)
        lastError = nil
    }

    func clearBinding(commandID: String) throws {
        guard CommandPaletteCommandCatalog.editable.contains(where: { $0.commandID == commandID }) else { return }
        var list = try decodedBindingsFromEditor()
        // Clearing a catalog command is an explicit user action, so it removes
        // every context-specific row for that command. Automatic normalization and
        // primary-row edits preserve those rows; this is the deliberate "disable
        // this command everywhere" operation exposed by the one-row settings UI.
        list.removeAll { $0.command == commandID }
        try applyNormalizedPersisting(list)
        lastError = nil
    }

    private func decodedBindingsFromEditor() throws -> [CommandPaletteKeyBinding] {
        try JSONDecoder().decode(CommandPaletteKeymapFile.self, from: Data(editorText.utf8)).bindings
    }

    /// Orders rows for display without dropping any of them: catalog commands first in
    /// catalog order, then non-catalog rows sorted by command. A command may legitimately
    /// own several rows scoped to different `when` contexts — the runtime indexes all of
    /// them and filters by context at dispatch time — so normalization must be a stable
    /// reordering, never a de-duplication (#279).
    private func normalizedBindingList(_ bindings: [CommandPaletteKeyBinding]) -> [CommandPaletteKeyBinding] {
        let catalogIDs = Set(CommandPaletteCommandCatalog.editable.map(\.commandID))
        let extras = bindings.filter { !catalogIDs.contains($0.command) }.sorted { $0.command < $1.command }
        let catalogOrdered = CommandPaletteCommandCatalog.editable.flatMap { spec in
            bindings.filter { $0.command == spec.commandID }
        }
        return catalogOrdered + extras
    }

    private func applyNormalizedPersisting(_ bindings: [CommandPaletteKeyBinding]) throws {
        let normalized = normalizedBindingList(bindings)
        // Indexing validates every row and every keystroke. Do it before the settings
        // store writes so an invalid advanced edit cannot partially replace the file.
        let indexed = try Self.indexBindings(normalized)
        try settingsStore.updateKeybinds(normalized)
        // Re-render the focused JSON snippet from the canonical normalized list so the
        // editor view always matches what is on disk.
        editorText = Self.editorTextRepresentation(normalized)
        self.bindings = indexed
    }

    private static func conflictingCommandID(
        for shortcut: CommandShortcut,
        excludingCommand: String,
        proposedWhen: CommandPaletteContext,
        in list: [CommandPaletteKeyBinding]
    ) -> String? {
        for binding in list {
            guard binding.command != excludingCommand else { continue }
            guard bindingContains(shortcut, in: binding) else { continue }
            if CommandPaletteContext.bindingsOverlapInRuntime(binding.when, proposedWhen) {
                return binding.command
            }
        }
        return nil
    }

    private static func bindingContains(
        _ shortcut: CommandShortcut,
        in binding: CommandPaletteKeyBinding
    ) -> Bool {
        binding.keystrokes.contains { (try? CommandShortcut(keystroke: $0)) == shortcut }
    }

    func commandBindings(for event: NSEvent, context: CommandPaletteContext) -> [CommandPaletteKeyBinding] {
        guard let shortcut = CommandShortcut(event: event) else { return [] }
        let candidates = bindings[shortcut] ?? []
        return candidates.filter { binding in
            guard let when = binding.when else { return true }
            return when == .always || when == context
        }
    }

    func applyEditorText() {
        do {
            let parsed = try JSONDecoder().decode(CommandPaletteKeymapFile.self, from: Data(editorText.utf8))
            try applyNormalizedPersisting(parsed.bindings)
            lastError = nil
        } catch {
            lastError = CommandPaletteKeymapErrorPresenter.message(
                for: error,
                source: SpotiglassL10n.string("palette.settings.advanced"),
                operation: "apply"
            )
        }
    }

    func reloadFromDisk() {
        settingsStore.reloadFromDisk()
        applyFromStore(settingsStore.settings.keybinds)
        if settingsStore.lastError != nil {
            // SpotiglassSettingsStore logs the underlying decode or I/O error. Do
            // not forward its raw description into the command-palette UI.
            lastError = CommandPaletteKeymapErrorPresenter.settingsReloadFailureMessage(source: fileURL.path)
        }
    }

    func resetToDefaults() {
        do {
            try applyNormalizedPersisting(SpotiglassSettingsStore.defaultKeybinds())
            lastError = nil
        } catch {
            lastError = CommandPaletteKeymapErrorPresenter.message(
                for: error,
                source: fileURL.path,
                operation: "reset"
            )
        }
    }

    func openKeymapFile() {
        settingsStore.openFileInDefaultEditor()
    }

    private func applyFromStore(_ keybinds: [CommandPaletteKeyBinding]) {
        do {
            try indexCurrent(keybinds)
            editorText = Self.editorTextRepresentation(keybinds)
            lastError = nil
        } catch {
            // Fall back to defaults so the app never runs without a usable keymap.
            let fallback = SpotiglassSettingsStore.defaultKeybinds()
            (try? indexCurrent(fallback)) ?? ()
            editorText = Self.editorTextRepresentation(fallback)
            lastError = CommandPaletteKeymapErrorPresenter.recoveredDefaultsMessage(
                for: error,
                source: fileURL.path,
                operation: "load"
            )
        }
    }

    private func indexCurrent(_ list: [CommandPaletteKeyBinding]) throws {
        bindings = try Self.indexBindings(list)
    }

    private static func indexBindings(_ bindings: [CommandPaletteKeyBinding]) throws -> [CommandShortcut: [CommandPaletteKeyBinding]] {
        var output: [CommandShortcut: [CommandPaletteKeyBinding]] = [:]
        for binding in bindings {
            try binding.validate()
            for keystroke in binding.keystrokes {
                let shortcut = try CommandShortcut(keystroke: keystroke)
                output[shortcut, default: []].append(binding)
            }
        }
        return output
    }

    /// Serializes the focused keybinds slice for the in-app JSON editor. The on-disk
    /// `settings.json` always contains the full ``SpotiglassSettingsFile``; this snippet
    /// is just what the user sees and edits in the GUI.
    static func editorTextRepresentation(_ bindings: [CommandPaletteKeyBinding]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(CommandPaletteKeymapFile(bindings: bindings)),
              let text = String(data: data, encoding: .utf8)
        else {
            return defaultKeymapText
        }
        // Foundation's `.prettyPrinted` emits a space before each key's colon
        // (`"command" : "…"`), which standard JSON formatters churn on round-trip.
        // The separator `" : "` only appears between a quoted key and its value
        // here (values are followed by `,`/newline, never `:`), so this rewrite to
        // `"key": value` is safe for this fixed schema.
        return text.replacingOccurrences(of: "\" : ", with: "\": ")
    }

    static let defaultKeymapText = CommandPaletteCommandCatalog.defaultKeymapJSON
}
