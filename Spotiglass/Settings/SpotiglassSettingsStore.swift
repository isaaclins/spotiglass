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

    /// The last document known to be on disk before any unsaved local staging.
    /// Three-way merging against this baseline keeps an external edit to a
    /// different setting from being overwritten by a stale in-memory snapshot.
    private var lastKnownDiskSettings: SpotiglassSettingsFile?

    /// Raw content observed after the last load or write. File-system sources can
    /// deliver more than one event for a single replacement; this identity makes
    /// those duplicate events harmless without suppressing a different document.
    private var lastObservedFileData: Data?
    private var hasObservedFileData = false

    /// Exact content of the most recent write performed by this store. A watcher
    /// event is ignored only when the file still contains these bytes, rather than
    /// merely because some event happened after a local write.
    private var lastOwnWriteData: Data?

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

    /// Read-modify-write helper. Mutations on the inout copy are persisted atomically.
    func mutate(_ change: (inout SpotiglassSettingsFile) -> Void) throws {
        var next = settings
        change(&next)
        try persist(next)
    }

    /// Updates the in-memory settings without writing to disk — for high-frequency
    /// edits (e.g. a slider drag) where every tick should publish to observers but
    /// only the final value is worth an atomic file write. Call
    /// ``persistStagedSettings()`` when the interaction ends; any later `mutate`
    /// also persists whatever was staged.
    func stage(_ change: (inout SpotiglassSettingsFile) -> Void) {
        var next = settings
        change(&next)
        settings = next
    }

    /// Writes the current (possibly staged) in-memory settings to disk.
    func persistStagedSettings() throws {
        try persist(settings)
    }

    func reloadFromDisk() {
        do {
            let content = try Data(contentsOf: fileURL)
            if let lastOwnWriteData, lastOwnWriteData != content {
                self.lastOwnWriteData = nil
            }
            rememberObservedFileData(content)
            let loaded = try decodeSettings(content)
            try applyLoadedSettings(
                loaded.settings,
                didRepair: loaded.didRepair,
                preserveLocalChanges: true
            )
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            SpotiglassLog.error(SpotiglassLog.settings, "Settings reload failed: \(error.localizedDescription)")
        }
    }

    /// Drops legacy `playlists.refreshTracks` rows (formerly default ⌘T) so refresh is only `playlists.refresh` / ⌘R,
    /// and seeds default keystrokes for catalog commands added after this file was written
    /// (e.g. `palette.enqueue` / ⇧↩) so existing installs pick up new shortcuts.
    private func applyLoadedSettings(
        _ parsed: SpotiglassSettingsFile,
        didRepair: Bool,
        preserveLocalChanges: Bool
    ) throws {
        let incoming: SettingsMergeResult
        if preserveLocalChanges {
            incoming = Self.mergedSettings(local: settings, baseline: lastKnownDiskSettings, disk: parsed)
        } else {
            incoming = SettingsMergeResult(settings: parsed, conflicts: [])
        }
        var next = incoming.settings
        var changed = false
        // Establish the legacy catalog baseline before any new-default seeding. A
        // missing metadata field means old commands may have been deliberately
        // cleared, so treating it as an empty tracked list would resurrect them.
        if Self.migrateKeybindSeedMetadata(into: &next) {
            changed = true
        }
        let sanitized = next.keybinds.filter { $0.command != CommandPaletteCommandID.refreshTracks }
        if sanitized.count != next.keybinds.count {
            next.keybinds = sanitized
            changed = true
        }
        // Renames run before seeding: a stale row still holding the chord makes
        // the new command's default look taken, so it is skipped and the
        // shortcut dies on every existing install (#198).
        if Self.migrateRenamedCommandIDs(into: &next) {
            changed = true
        }
        if Self.seedNewDefaultKeybinds(into: &next) {
            changed = true
        }

        // `parsed` is the new three-way merge baseline. If a local staged value
        // was retained, it remains a local difference and can be persisted later.
        lastKnownDiskSettings = parsed
        if changed || didRepair {
            settings = next
            try persist(next)
        } else {
            settings = next
        }
    }

    /// Three-way merge at the persisted-field boundary. A local value is applied
    /// only when it differs from the last disk baseline; untouched local fields
    /// therefore inherit a newer external value. When both sides changed the
    /// same field, the explicit local mutation wins and the conflict is logged.
    private static func mergedSettings(
        local: SpotiglassSettingsFile,
        baseline: SpotiglassSettingsFile?,
        disk: SpotiglassSettingsFile
    ) -> SettingsMergeResult {
        guard let baseline else {
            return SettingsMergeResult(settings: disk, conflicts: [])
        }

        var merged = disk
        var conflicts: [String] = []

        func choose<T: Equatable>(
            _ localValue: T,
            baseline baselineValue: T,
            disk diskValue: T,
            field: String
        ) -> T {
            let localChanged = localValue != baselineValue
            let diskChanged = diskValue != baselineValue
            if localChanged && diskChanged && localValue != diskValue {
                conflicts.append(field)
            }
            return localChanged ? localValue : diskValue
        }

        merged.version = choose(local.version, baseline: baseline.version, disk: disk.version, field: "version")
        merged.keybinds = choose(local.keybinds, baseline: baseline.keybinds, disk: disk.keybinds, field: "keybinds")
        merged.seededKeybindCommands = choose(
            local.seededKeybindCommands,
            baseline: baseline.seededKeybindCommands,
            disk: disk.seededKeybindCommands,
            field: "seededKeybindCommands"
        )
        merged.keybindSeedBaselineVersion = choose(
            local.keybindSeedBaselineVersion,
            baseline: baseline.keybindSeedBaselineVersion,
            disk: disk.keybindSeedBaselineVersion,
            field: "keybindSeedBaselineVersion"
        )

        merged.appearance.language = choose(
            local.appearance.language,
            baseline: baseline.appearance.language,
            disk: disk.appearance.language,
            field: "appearance.language"
        )
        merged.appearance.colorScheme = choose(
            local.appearance.colorScheme,
            baseline: baseline.appearance.colorScheme,
            disk: disk.appearance.colorScheme,
            field: "appearance.colorScheme"
        )
        merged.appearance.lyricsTextSize = choose(
            local.appearance.lyricsTextSize,
            baseline: baseline.appearance.lyricsTextSize,
            disk: disk.appearance.lyricsTextSize,
            field: "appearance.lyricsTextSize"
        )
        merged.appearance.lyricsOffsetMilliseconds = choose(
            local.appearance.lyricsOffsetMilliseconds,
            baseline: baseline.appearance.lyricsOffsetMilliseconds,
            disk: disk.appearance.lyricsOffsetMilliseconds,
            field: "appearance.lyricsOffsetMilliseconds"
        )
        merged.appearance.lyricsTextScale = choose(
            local.appearance.lyricsTextScale,
            baseline: baseline.appearance.lyricsTextScale,
            disk: disk.appearance.lyricsTextScale,
            field: "appearance.lyricsTextScale"
        )

        merged.commandPalette.backdropBlur = choose(
            local.commandPalette.backdropBlur,
            baseline: baseline.commandPalette.backdropBlur,
            disk: disk.commandPalette.backdropBlur,
            field: "commandPalette.backdropBlur"
        )

        merged.equalizer.enabled = choose(
            local.equalizer.enabled,
            baseline: baseline.equalizer.enabled,
            disk: disk.equalizer.enabled,
            field: "equalizer.enabled"
        )
        merged.equalizer.preamp = choose(
            local.equalizer.preamp,
            baseline: baseline.equalizer.preamp,
            disk: disk.equalizer.preamp,
            field: "equalizer.preamp"
        )
        merged.equalizer.bands = choose(
            local.equalizer.bands,
            baseline: baseline.equalizer.bands,
            disk: disk.equalizer.bands,
            field: "equalizer.bands"
        )
        merged.equalizer.activePresetName = choose(
            local.equalizer.activePresetName,
            baseline: baseline.equalizer.activePresetName,
            disk: disk.equalizer.activePresetName,
            field: "equalizer.activePresetName"
        )
        merged.equalizer.userPresets = choose(
            local.equalizer.userPresets,
            baseline: baseline.equalizer.userPresets,
            disk: disk.equalizer.userPresets,
            field: "equalizer.userPresets"
        )
        merged.equalizer.forwardingTargetUID = choose(
            local.equalizer.forwardingTargetUID,
            baseline: baseline.equalizer.forwardingTargetUID,
            disk: disk.equalizer.forwardingTargetUID,
            field: "equalizer.forwardingTargetUID"
        )

        return SettingsMergeResult(settings: merged, conflicts: conflicts)
    }

    /// IDs that had a default binding before seeded-keybind metadata was introduced.
    /// A pre-metadata file cannot reveal whether one of these rows was deliberately
    /// removed, so migration records this fixed historical baseline instead of
    /// seeding those commands again. Commands added (or given a default) later stay
    /// outside this list and are eligible for normal one-time seeding.
    private static let legacyKeybindSeedBaseline: [String] = [
        CommandPaletteCommandID.openPalette,
        CommandPaletteCommandID.refreshPlaylists,
        CommandPaletteCommandID.connectPlayback,
        CommandPaletteCommandID.togglePlayback,
        CommandPaletteCommandID.nextTrack,
        CommandPaletteCommandID.previousTrack,
        CommandPaletteCommandID.toggleQueue,
        CommandPaletteCommandID.openSettings,
        CommandPaletteCommandID.pinSelected,
        CommandPaletteCommandID.enqueueSelected,
    ]

    /// Converts pre-metadata documents into the tracked schema before defaults are
    /// seeded. Explicit metadata (including an empty list) is left untouched.
    private static func migrateKeybindSeedMetadata(into file: inout SpotiglassSettingsFile) -> Bool {
        var changed = false
        if file.keybindSeedBaselineVersion < SpotiglassSettingsFile.currentKeybindSeedBaselineVersion {
            let alreadySeeded = Set(file.seededKeybindCommands)
            for commandID in legacyKeybindSeedBaseline where !alreadySeeded.contains(commandID) {
                file.seededKeybindCommands.append(commandID)
            }
            file.keybindSeedBaselineVersion = SpotiglassSettingsFile.currentKeybindSeedBaselineVersion
            changed = true
        }
        if file.version < SpotiglassSettingsFile.currentVersion {
            file.version = SpotiglassSettingsFile.currentVersion
            changed = true
        }
        return changed
    }

    /// Command IDs whose spelling changed after installs already had bindings
    /// saved under the old one.
    ///
    /// A saved binding names its command by string, so renaming the constant
    /// leaves the old row pointing at a command that no longer exists while the
    /// real command answers to nothing. Add an entry here whenever a
    /// ``CommandPaletteCommandID`` value changes.
    static let renamedCommandIDs: [String: String] = [
        "search.open": CommandPaletteCommandID.openSearch,
    ]

    /// Repoints saved bindings at the current command IDs. A row whose new ID is
    /// already bound is dropped rather than duplicated, so the user's own choice
    /// wins over the stale one. Returns true when the file needs persisting.
    static func migrateRenamedCommandIDs(into file: inout SpotiglassSettingsFile) -> Bool {
        guard file.keybinds.contains(where: { renamedCommandIDs[$0.command] != nil }) else {
            return false
        }
        var claimed = Set(file.keybinds.filter { renamedCommandIDs[$0.command] == nil }.map(\.command))
        var migrated: [CommandPaletteKeyBinding] = []
        for binding in file.keybinds {
            guard let currentID = renamedCommandIDs[binding.command] else {
                migrated.append(binding)
                continue
            }
            guard !claimed.contains(currentID) else { continue }
            claimed.insert(currentID)
            var renamed = binding
            renamed.command = currentID
            migrated.append(renamed)
        }
        file.keybinds = migrated
        return true
    }

    /// Adds the default binding for every catalog command that has one but is not yet
    /// recorded in ``SpotiglassSettingsFile/seededKeybindCommands``. Skips a default whose
    /// keystroke the user already assigned to something else in an overlapping context.
    /// Returns true when the file was mutated and needs persisting.
    private static func seedNewDefaultKeybinds(into file: inout SpotiglassSettingsFile) -> Bool {
        let alreadySeeded = Set(file.seededKeybindCommands)
        let boundCommands = Set(file.keybinds.map(\.command))
        var changed = false
        for spec in CommandPaletteCommandCatalog.editable {
            guard let keystroke = spec.defaultKeystroke, !alreadySeeded.contains(spec.commandID) else { continue }
            if !boundCommands.contains(spec.commandID),
               !defaultShortcutTaken(keystroke: keystroke, when: spec.defaultWhen, in: file.keybinds) {
                file.keybinds.append(
                    CommandPaletteKeyBinding(
                        keystrokes: [keystroke],
                        command: spec.commandID,
                        when: spec.defaultWhen,
                        args: nil
                    )
                )
            }
            file.seededKeybindCommands.append(spec.commandID)
            changed = true
        }
        return changed
    }

    private static func defaultShortcutTaken(
        keystroke: String,
        when: CommandPaletteContext,
        in keybinds: [CommandPaletteKeyBinding]
    ) -> Bool {
        guard let shortcut = try? CommandShortcut(keystroke: keystroke) else { return true }
        return keybinds.contains { binding in
            binding.keystrokes.contains { (try? CommandShortcut(keystroke: $0)) == shortcut }
                && CommandPaletteContext.bindingsOverlapInRuntime(binding.when, when)
        }
    }

    func openFileInDefaultEditor() {
        NSWorkspace.shared.open(fileURL)
    }

    // MARK: - Persistence

    private struct DecodedSettings {
        let settings: SpotiglassSettingsFile
        let didRepair: Bool
    }

    private struct SettingsDiskSnapshot {
        let data: Data
        let decoded: DecodedSettings
    }

    private struct SettingsMergeResult {
        let settings: SpotiglassSettingsFile
        let conflicts: [String]
    }

    private func decodeSettings(_ data: Data) throws -> DecodedSettings {
        let tracker = SpotiglassSettingsDecodeTracker()
        let decoder = JSONDecoder()
        decoder.userInfo[.spotiglassSettingsDecodeTracker] = tracker
        let settings = try decoder.decode(SpotiglassSettingsFile.self, from: data)
        return DecodedSettings(settings: settings, didRepair: tracker.didRepair)
    }

    private func readDiskSnapshot() throws -> SettingsDiskSnapshot? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return SettingsDiskSnapshot(data: data, decoded: try decodeSettings(data))
    }

    /// A syntactically invalid document cannot provide a merge base. It is safe
    /// to replace that document with the proposed settings, matching bootstrap's
    /// existing whole-document fallback while keeping valid documents protected.
    private func readDiskSnapshotForWrite() throws -> SettingsDiskSnapshot? {
        do {
            return try readDiskSnapshot()
        } catch is DecodingError {
            SpotiglassLog.error(
                SpotiglassLog.settings,
                "Settings document is not parseable; replacing it with the next valid snapshot."
            )
            return nil
        }
    }

    private func persist(_ proposed: SpotiglassSettingsFile) throws {
        try ensureDirectory()

        // Read immediately before encoding, then check once more before replacing
        // the file. The second snapshot closes the common race where an editor
        // saves while a staged UI value is being prepared.
        let firstSnapshot = try readDiskSnapshotForWrite()
        var currentSnapshot = firstSnapshot
        let latestSnapshot = try readDiskSnapshotForWrite()
        if firstSnapshot?.data != latestSnapshot?.data {
            currentSnapshot = latestSnapshot
        }

        let merge: SettingsMergeResult
        if let currentSnapshot, let baseline = lastKnownDiskSettings {
            merge = Self.mergedSettings(
                local: proposed,
                baseline: baseline,
                disk: currentSnapshot.decoded.settings
            )
        } else {
            merge = SettingsMergeResult(settings: proposed, conflicts: [])
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(merge.settings)
        try data.write(to: fileURL, options: .atomic)

        // The watcher may receive an event for the old inode after this method
        // returns. Remember the exact replacement so only this write is ignored;
        // a different external document is still reloaded.
        rememberObservedFileData(data)
        lastOwnWriteData = data
        lastKnownDiskSettings = merge.settings
        settings = merge.settings
        lastError = nil

        if !merge.conflicts.isEmpty {
            SpotiglassLog.info(
                SpotiglassLog.settings,
                "Merged local settings with concurrent external changes; local values won for: \(merge.conflicts.joined(separator: ", "))."
            )
        }
    }

    private func loadOrBootstrap() {
        do {
            if !fileManager.fileExists(atPath: fileURL.path) {
                try ensureDirectory()
                try persist(Self.bootstrapDefaults())
                return
            }
            let data = try Data(contentsOf: fileURL)
            rememberObservedFileData(data)
            let loaded = try decodeSettings(data)
            try applyLoadedSettings(
                loaded.settings,
                didRepair: loaded.didRepair,
                preserveLocalChanges: false
            )
            lastError = nil
        } catch {
            do {
                let fallback = Self.bootstrapDefaults()
                lastKnownDiskSettings = nil
                settings = fallback
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
                self.processObservedFileChange()
                self.startWatchingFile()
            }
            return
        }
        processObservedFileChange()
    }

    private func processObservedFileChange() {
        let currentData = try? Data(contentsOf: fileURL)

        // A self-write is identified by its exact content. If an external editor
        // replaces the file before this callback runs, the bytes differ and the
        // edit is reloaded instead of being swallowed by a one-shot flag.
        if let lastOwnWriteData, currentData == lastOwnWriteData {
            rememberObservedFileData(currentData)
            return
        }

        // A single editor save can produce several write/rename notifications.
        // Coalesce only an identical already-observed document; a new document
        // always reaches reloadFromDisk exactly once for this store.
        if hasObservedFileData, currentData == lastObservedFileData {
            return
        }
        // This is a new external generation, so an old self-write token must not
        // suppress a later external replacement that happens to reuse its bytes.
        lastOwnWriteData = nil
        rememberObservedFileData(currentData)
        reloadFromDisk()
    }

    private func rememberObservedFileData(_ data: Data?) {
        lastObservedFileData = data
        hasObservedFileData = true
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
            keybinds: defaultKeybinds(),
            seededKeybindCommands: CommandPaletteCommandCatalog.editable
                .filter { $0.defaultKeystroke != nil }
                .map(\.commandID)
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
