import AppKit
import Combine
import Foundation

/// Single source of truth for `~/Library/Application Support/Spotiglass/settings.json`
/// (migrated once from the legacy `~/.config/spotiglass/settings.json` on first launch).
///
/// The keymap UI and other settings panes read and write through this store so that
/// every user-editable setting lives in a single JSON file. The store performs atomic
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
        let resolvedURL = customFileURL ?? Self.defaultFileURL(fileManager: fileManager)
        // Production (default-path) launches only: relocate a pre-existing config
        // from the old Linux-style `~/.config/spotiglass` location to the
        // macOS-standard Application Support path so the two no longer coexist (#27).
        // Tests pass an explicit `fileURL` and intentionally skip this.
        if customFileURL == nil {
            Self.migrateLegacyConfigIfNeeded(
                fileManager: fileManager,
                from: Self.legacyFileURL(fileManager: fileManager),
                to: resolvedURL
            )
        }
        self.fileURL = resolvedURL
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

    func updateEqualizer(_ equalizer: EqualizerSettings) throws {
        var next = settings
        next.equalizer = equalizer
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

    /// Canonical settings location: `~/Library/Application Support/Spotiglass/settings.json`,
    /// alongside the app's `Spotiglass/Logs` directory, so all app data lives under
    /// the macOS-standard path (#27).
    static func defaultFileURL(fileManager: FileManager) -> URL {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? fileManager
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Spotiglass", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    /// Pre-1.0 location on macOS: `~/.config/spotiglass/settings.json` (a Linux
    /// convention). Retained only so existing installs can be migrated forward.
    static func legacyFileURL(fileManager: FileManager) -> URL {
        fileManager
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("spotiglass", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    /// One-time move of the legacy config to the new location. No-op when the new
    /// file already exists (never clobbers current settings) or when there is no
    /// legacy file. Failures are logged and non-fatal — the caller bootstraps a
    /// fresh file at the new path instead.
    static func migrateLegacyConfigIfNeeded(fileManager: FileManager, from legacyURL: URL, to newURL: URL) {
        guard !fileManager.fileExists(atPath: newURL.path),
              fileManager.fileExists(atPath: legacyURL.path)
        else { return }
        do {
            try fileManager.createDirectory(
                at: newURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: legacyURL, to: newURL)
            SpotiglassLog.info(.settings, "Migrated settings.json from ~/.config/spotiglass to Application Support.")
        } catch {
            SpotiglassLog.error(.settings, "Settings migration from legacy location failed: \(error.localizedDescription)")
        }
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
