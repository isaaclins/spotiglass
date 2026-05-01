import AppKit
import Foundation

@MainActor
final class CommandPaletteKeymapStore: ObservableObject {
    @Published private(set) var bindings: [CommandShortcut: [CommandPaletteKeyBinding]] = [:]
    @Published var editorText: String = ""
    @Published var lastError: String?
    @Published private(set) var fileURL: URL

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = Self.defaultFileURL(fileManager: fileManager)
        loadOrBootstrap()
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

    static let defaultKeymapText = """
    {
      "bindings": [
        { "keystrokes": ["cmd-k"], "command": "palette.open", "when": "always" },
        { "keystrokes": ["cmd-r"], "command": "playlists.refresh", "when": "signed_in" },
        { "keystrokes": ["cmd-t"], "command": "playlists.refreshTracks", "when": "signed_in" },
        { "keystrokes": ["shift-cmd-k"], "command": "playback.connect", "when": "signed_in" },
        { "keystrokes": ["space"], "command": "playback.toggle", "when": "signed_in" },
        { "keystrokes": ["shift-cmd-right"], "command": "playback.next", "when": "signed_in" },
        { "keystrokes": ["shift-cmd-left"], "command": "playback.previous", "when": "signed_in" },
        { "keystrokes": ["cmd-,"], "command": "app.openSettings", "when": "always" }
      ]
    }
    """
}
