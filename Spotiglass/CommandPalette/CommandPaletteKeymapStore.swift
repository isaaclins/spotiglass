import AppKit
import Foundation

@MainActor
final class CommandPaletteKeymapStore: ObservableObject {
    @Published private(set) var bindings: [CommandShortcut: [CommandPaletteKeyBinding]] = [:]
    @Published var editorText: String = ""
    @Published var lastError: String?
    @Published private(set) var fileURL: URL

    private let fileManager: FileManager

    init(fileManager: FileManager = .default, fileURL customFileURL: URL? = nil) {
        self.fileManager = fileManager
        self.fileURL = customFileURL ?? Self.defaultFileURL(fileManager: fileManager)
        loadOrBootstrap()
    }

    // MARK: - Structured editing (Settings GUI)

    /// First shortcut for a catalog command, if any.
    func primaryShortcut(for commandID: String) -> CommandShortcut? {
        guard let list = try? decodedBindingsFromEditor() else { return nil }
        return list.first { $0.command == commandID }
            .flatMap(\.keystrokes.first)
            .flatMap { try? CommandShortcut(keystroke: $0) }
    }

    /// Returns another command id that already uses this shortcut in an overlapping runtime context.
    func conflictingCommandID(for shortcut: CommandShortcut, proposedForCommand commandID: String) -> String? {
        guard let spec = CommandPaletteCommandCatalog.editable.first(where: { $0.commandID == commandID }),
              let list = try? decodedBindingsFromEditor()
        else { return nil }
        return Self.conflictingCommandID(
            for: shortcut,
            excludingCommand: commandID,
            proposedWhen: spec.defaultWhen,
            in: list
        )
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(CommandPaletteKeymapFile(bindings: normalized))
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSCocoaErrorDomain, code: 517, userInfo: nil) // NSFileWriteIncompatibleStringEncodingError
        }
        try apply(text: text, persist: true)
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
            try apply(text: editorText, persist: true)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func reloadFromDisk() {
        do {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            try apply(text: content, persist: false)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func resetToDefaults() {
        do {
            let defaults = Self.defaultKeymapText
            try apply(text: defaults, persist: true)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func openKeymapFile() {
        NSWorkspace.shared.open(fileURL)
    }

    private func loadOrBootstrap() {
        do {
            if !fileManager.fileExists(atPath: fileURL.path) {
                try ensureDirectory()
                try Self.defaultKeymapText.write(to: fileURL, atomically: true, encoding: .utf8)
            }
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            try apply(text: content, persist: false)
        } catch {
            do {
                // Never leave the app without active bindings: fallback to defaults
                // if disk contents are missing or malformed.
                try apply(text: Self.defaultKeymapText, persist: true)
                lastError = "Keymap on disk was invalid and has been reset to defaults. \(error.localizedDescription)"
            } catch {
                editorText = Self.defaultKeymapText
                bindings = [:]
                lastError = error.localizedDescription
            }
        }
    }

    private func apply(text: String, persist: Bool) throws {
        let data = Data(text.utf8)
        let parsed = try JSONDecoder().decode(CommandPaletteKeymapFile.self, from: data)
        let indexed = try Self.indexBindings(parsed.bindings)
        if persist {
            try ensureDirectory()
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        editorText = text
        bindings = indexed
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
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

    private static func defaultFileURL(fileManager: FileManager) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        return appSupport
            .appendingPathComponent("Spotiglass", isDirectory: true)
            .appendingPathComponent("keymap.json")
    }

    static let defaultKeymapText = CommandPaletteCommandCatalog.defaultKeymapJSON
}
