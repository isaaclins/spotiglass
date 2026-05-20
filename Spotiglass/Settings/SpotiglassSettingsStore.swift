import AppKit
import Combine
import Foundation

/// Single source of truth for `~/.config/spotiglass/settings.json`.
///
/// The keymap UI and other settings panes read and write through this store so that
/// every user-editable setting lives in a single dotfile. The store performs atomic
/// writes, watches the file for external edits via `DispatchSourceFileSystemObject`,
/// and bootstraps a default file on first launch.
@MainActor
final class SpotiglassSettingsStore: ObservableObject {
    @Published private(set) var settings: SpotiglassSettingsFile
    @Published private(set) var fileURL: URL
    @Published var lastError: String?

    private let fileManager: FileManager
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var watcherDescriptor: Int32 = -1
    private var ignoreNextExternalChange: Bool = false

    init(fileManager: FileManager = .default, fileURL customFileURL: URL? = nil) {
        self.fileManager = fileManager
        self.fileURL = customFileURL ?? Self.defaultFileURL(fileManager: fileManager)
        self.settings = Self.bootstrapDefaults()
        loadOrBootstrap()
        startWatchingFile()
    }

    deinit {
        fileWatcher?.cancel()
        if watcherDescriptor >= 0 {
            close(watcherDescriptor)
        }
    }

    // MARK: - Public API

    var appLocale: Locale {
        Locale(identifier: settings.appearance.language.rawValue)
    }

    func updateKeybinds(_ keybinds: [CommandPaletteKeyBinding]) throws {
        var next = settings
        next.keybinds = keybinds
        try persist(next)
    }

    /// Read-modify-write helper. Mutations on the inout copy are persisted atomically.
    func mutate(_ change: (inout SpotiglassSettingsFile) -> Void) throws {
        var next = settings
        change(&next)
        try persist(next)
    }

    func reloadFromDisk() {
        do {
            let content = try Data(contentsOf: fileURL)
            let parsed = try JSONDecoder().decode(SpotiglassSettingsFile.self, from: content)
            try applyLoadedSettings(parsed)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            SpotiglassLog.error(SpotiglassLog.settings, "Settings reload failed: \(error.localizedDescription)")
        }
    }

    /// Drops legacy `playlists.refreshTracks` rows (formerly default ⌘T) so refresh is only `playlists.refresh` / ⌘R.
    private func applyLoadedSettings(_ parsed: SpotiglassSettingsFile) throws {
        let sanitized = parsed.keybinds.filter { $0.command != CommandPaletteCommandID.refreshTracks }
        if sanitized.count != parsed.keybinds.count {
            var next = parsed
            next.keybinds = sanitized
            try persist(next)
        } else {
            settings = parsed
        }
    }

    func openFileInDefaultEditor() {
        NSWorkspace.shared.open(fileURL)
    }

    // MARK: - Persistence

    private func persist(_ next: SpotiglassSettingsFile) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(next)
        ignoreNextExternalChange = true
        try data.write(to: fileURL, options: .atomic)
        settings = next
        lastError = nil
    }

    private func loadOrBootstrap() {
        do {
            if !fileManager.fileExists(atPath: fileURL.path) {
                try ensureDirectory()
                try persist(Self.bootstrapDefaults())
                return
            }
            let data = try Data(contentsOf: fileURL)
            let parsed = try JSONDecoder().decode(SpotiglassSettingsFile.self, from: data)
            try applyLoadedSettings(parsed)
            lastError = nil
        } catch {
            do {
                let fallback = Self.bootstrapDefaults()
                try persist(fallback)
                lastError = "Settings file was invalid and has been reset to defaults. \(error.localizedDescription)"
            } catch {
                lastError = error.localizedDescription
                SpotiglassLog.error(SpotiglassLog.settings, "Settings bootstrap failed: \(error.localizedDescription)")
            }
        }
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    // MARK: - File watching

    private func startWatchingFile() {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        let descriptor = open(fileURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.handleFileEvent()
        }
        source.setCancelHandler { [descriptor] in
            close(descriptor)
        }
        watcherDescriptor = descriptor
        fileWatcher = source
        source.resume()
    }

    private func handleFileEvent() {
        let mask = fileWatcher?.data ?? []
        if mask.contains(.delete) || mask.contains(.rename) {
            // File replaced (atomic write, editor save) — restart the watcher on the new inode.
            fileWatcher?.cancel()
            fileWatcher = nil
            watcherDescriptor = -1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                if !self.ignoreNextExternalChange {
                    self.reloadFromDisk()
                }
                self.ignoreNextExternalChange = false
                self.startWatchingFile()
            }
            return
        }
        if ignoreNextExternalChange {
            ignoreNextExternalChange = false
            return
        }
        reloadFromDisk()
    }

    // MARK: - Defaults

    static func defaultFileURL(fileManager: FileManager) -> URL {
        fileManager
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("spotiglass", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    static func bootstrapDefaults() -> SpotiglassSettingsFile {
        SpotiglassSettingsFile(
            version: SpotiglassSettingsFile.currentVersion,
            keybinds: defaultKeybinds()
        )
    }

    static func defaultKeybinds() -> [CommandPaletteKeyBinding] {
        let json = CommandPaletteCommandCatalog.defaultKeymapJSON
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(CommandPaletteKeymapFile.self, from: data)
        else {
            return []
        }
        return parsed.bindings
    }
}
