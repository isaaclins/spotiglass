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
                guard let first = existing.keystrokes.first, let sh = try? CommandShortcut(keystroke: first) else {
                    return false
                }
                guard sh == shortcut else { return false }
                return CommandPaletteContext.bindingsOverlapInRuntime(existing.when, spec.defaultWhen)
            }
        }
        let preservedArgs = list.first { $0.command == commandID }?.args
        list.removeAll { $0.command == commandID }
        list.append(
            CommandPaletteKeyBinding(
                keystrokes: [try shortcut.canonicalToken()],
                command: commandID,
                when: spec.defaultWhen,
                args: preservedArgs
            )
        )
        try applyNormalizedPersisting(list)
        lastError = nil
    }

    func clearBinding(commandID: String) throws {
        guard CommandPaletteCommandCatalog.editable.contains(where: { $0.commandID == commandID }) else { return }
        var list = try decodedBindingsFromEditor()
        list.removeAll { $0.command == commandID }
        try applyNormalizedPersisting(list)
        lastError = nil
    }

    private func decodedBindingsFromEditor() throws -> [CommandPaletteKeyBinding] {
        try JSONDecoder().decode(CommandPaletteKeymapFile.self, from: Data(editorText.utf8)).bindings
    }

    private func normalizedBindingList(_ bindings: [CommandPaletteKeyBinding]) -> [CommandPaletteKeyBinding] {
        let catalogIDs = Set(CommandPaletteCommandCatalog.editable.map(\.commandID))
        let extras = bindings.filter { !catalogIDs.contains($0.command) }.sorted { $0.command < $1.command }
        let catalogOrdered = CommandPaletteCommandCatalog.editable.compactMap { spec in
            bindings.first { $0.command == spec.commandID }
        }
        return catalogOrdered + extras
    }

    private func applyNormalizedPersisting(_ bindings: [CommandPaletteKeyBinding]) throws {
        let normalized = normalizedBindingList(bindings)
        try settingsStore.updateKeybinds(normalized)
        // Re-render the focused JSON snippet from the canonical normalized list so the
        // editor view always matches what is on disk.
        editorText = Self.editorTextRepresentation(normalized)
        try indexCurrent(normalized)
    }

    private static func conflictingCommandID(
        for shortcut: CommandShortcut,
        excludingCommand: String,
        proposedWhen: CommandPaletteContext,
        in list: [CommandPaletteKeyBinding]
    ) -> String? {
        for binding in list {
            guard binding.command != excludingCommand else { continue }
            guard let first = binding.keystrokes.first, let sh = try? CommandShortcut(keystroke: first) else {
                continue
            }
            guard sh == shortcut else { continue }
            if CommandPaletteContext.bindingsOverlapInRuntime(binding.when, proposedWhen) {
                return binding.command
            }
        }
        return nil
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
            lastError = error.localizedDescription
        }
    }

    func reloadFromDisk() {
        settingsStore.reloadFromDisk()
        applyFromStore(settingsStore.settings.keybinds)
        if let storeError = settingsStore.lastError {
            lastError = storeError
        } else {
            lastError = nil
        }
    }

    func resetToDefaults() {
        do {
            try applyNormalizedPersisting(SpotiglassSettingsStore.defaultKeybinds())
            lastError = nil
        } catch {
            lastError = error.localizedDescription
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
            lastError =
                "Keybinds in settings.json were invalid and have been reset to defaults. \(error.localizedDescription)"
        }
    }

    private func indexCurrent(_ list: [CommandPaletteKeyBinding]) throws {
        bindings = try Self.indexBindings(list)
    }

    private static func indexBindings(_ bindings: [CommandPaletteKeyBinding]) throws -> [CommandShortcut:
        [CommandPaletteKeyBinding]]
    {
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
