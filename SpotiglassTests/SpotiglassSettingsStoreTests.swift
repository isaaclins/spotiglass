import XCTest
@testable import Spotiglass

@MainActor
final class SpotiglassSettingsStoreTests: XCTestCase {
    func testBootstrapWritesDefaultsWhenFileMissing() throws {
        let url = makeTempFileURL()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        let store = SpotiglassSettingsStore(fileURL: url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(store.settings.version, SpotiglassSettingsFile.currentVersion)
        XCTAssertTrue(store.settings.commandPalette.backdropBlur)
        XCTAssertEqual(store.settings.appearance.colorScheme, .system)
        XCTAssertFalse(store.settings.keybinds.isEmpty)
    }

    func testRoundTripPreservesKeybindsAndAppearance() throws {
        let url = makeTempFileURL()
        var original = SpotiglassSettingsStore.bootstrapDefaults()
        original.appearance = AppearanceSettings(colorScheme: .dark, lyricsTextScale: 1.8)
        original.commandPalette = CommandPaletteSettings(backdropBlur: false)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(original).write(to: url)

        let store = SpotiglassSettingsStore(fileURL: url)
        XCTAssertEqual(store.settings, original)
        XCTAssertEqual(store.settings.appearance.lyricsTextScale, 1.8)
    }

    func testLegacyFileWithoutScaleOrSeededListDecodesWithDefaults() throws {
        // Raw JSON shaped like a settings.json written before lyricsTextScale and
        // seededKeybindCommands existed — neither key present at all.
        let legacyJSON = """
        {
          "version" : 1,
          "keybinds" : [],
          "appearance" : { "colorScheme" : "dark" },
          "commandPalette" : { "backdropBlur" : true },
          "equalizer" : { }
        }
        """
        let decoded = try JSONDecoder().decode(SpotiglassSettingsFile.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.appearance.lyricsTextScale, 1.0)
        XCTAssertEqual(decoded.appearance.colorScheme, .dark)
    }

    /// A saved binding names its command by string, so renaming the constant
    /// left the old row holding the chord while the real command answered to
    /// nothing, and ⌘F silently stopped opening Search (#198).
    func testRenamedCommandIDsKeepTheirSavedShortcut() throws {
        var file = SpotiglassSettingsFile(keybinds: [
            CommandPaletteKeyBinding(keystrokes: ["cmd-f"], command: "search.open", when: .signedIn),
            CommandPaletteKeyBinding(keystrokes: ["cmd-r"], command: CommandPaletteCommandID.refreshPlaylists, when: .signedIn),
        ])

        XCTAssertTrue(SpotiglassSettingsStore.migrateRenamedCommandIDs(into: &file))
        XCTAssertEqual(
            file.keybinds.first { $0.keystrokes == ["cmd-f"] }?.command,
            CommandPaletteCommandID.openSearch
        )
        XCTAssertFalse(file.keybinds.contains { $0.command == "search.open" })
        XCTAssertEqual(file.keybinds.count, 2, "migration renames rows, it does not add or drop them")
        XCTAssertEqual(
            file.keybinds.first { $0.command == CommandPaletteCommandID.openSearch }?.when,
            .signedIn,
            "the context travels with the binding"
        )

        // Nothing to do on a file that already uses current IDs.
        XCTAssertFalse(SpotiglassSettingsStore.migrateRenamedCommandIDs(into: &file))
    }

    /// If the user has already bound the renamed command themselves, their
    /// choice wins and the stale row is dropped rather than duplicating it.
    func testRenameDropsTheStaleRowWhenTheCurrentCommandIsAlreadyBound() throws {
        var file = SpotiglassSettingsFile(keybinds: [
            CommandPaletteKeyBinding(keystrokes: ["cmd-f"], command: "search.open", when: .signedIn),
            CommandPaletteKeyBinding(keystrokes: ["alt-cmd-f"], command: CommandPaletteCommandID.openSearch, when: .signedIn),
        ])

        XCTAssertTrue(SpotiglassSettingsStore.migrateRenamedCommandIDs(into: &file))
        XCTAssertEqual(file.keybinds.count, 1)
        XCTAssertEqual(file.keybinds.first?.keystrokes, ["alt-cmd-f"])
    }

    func testOutOfRangeLyricsTextScaleClampsOnDecode() throws {
        func decodeScale(_ raw: Double) throws -> Double {
            let json = """
            { "keybinds" : [], "appearance" : { "lyricsTextScale" : \(raw) } }
            """
            return try JSONDecoder()
                .decode(SpotiglassSettingsFile.self, from: Data(json.utf8))
                .appearance.lyricsTextScale
        }
        XCTAssertEqual(try decodeScale(100.0), AppearanceSettings.lyricsTextScaleRange.upperBound)
        XCTAssertEqual(try decodeScale(-1.0), AppearanceSettings.lyricsTextScaleRange.lowerBound)
        XCTAssertEqual(try decodeScale(1.4), 1.4)
    }

    func testLyricsTextMetricsScaleMultipliesPresetValues() {
        let base = LyricsTextSize.medium.metrics()
        let doubled = LyricsTextSize.medium.metrics(scale: 2.0)
        XCTAssertEqual(doubled.activeFontSize, base.activeFontSize * 2)
        XCTAssertEqual(doubled.inactiveFontSize, base.inactiveFontSize * 2)
        XCTAssertEqual(doubled.timedLineSpacing, base.timedLineSpacing * 2)
        XCTAssertEqual(doubled.plainLineSpacing, base.plainLineSpacing * 2)
        XCTAssertEqual(doubled.activeGlowRadius, base.activeGlowRadius * 2)
    }

    func testStageUpdatesMemoryWithoutDiskWriteUntilPersistStaged() throws {
        let url = makeTempFileURL()
        let store = SpotiglassSettingsStore(fileURL: url)

        store.stage { $0.appearance.lyricsTextScale = 2.2 }

        XCTAssertEqual(store.settings.appearance.lyricsTextScale, 2.2)
        var onDisk = try JSONDecoder().decode(SpotiglassSettingsFile.self, from: Data(contentsOf: url))
        XCTAssertEqual(onDisk.appearance.lyricsTextScale, 1.0, "stage must not touch the file")

        try store.persistStagedSettings()
        onDisk = try JSONDecoder().decode(SpotiglassSettingsFile.self, from: Data(contentsOf: url))
        XCTAssertEqual(onDisk.appearance.lyricsTextScale, 2.2)
    }

    func testMalformedNestedFieldRepairsOnlyThatFieldAndPreservesSiblingSettings() throws {
        let url = makeTempFileURL()
        var original = SpotiglassSettingsStore.bootstrapDefaults()
        original.appearance = AppearanceSettings(
            language: .german,
            colorScheme: .dark,
            lyricsTextSize: .large,
            lyricsOffsetMilliseconds: 750,
            lyricsTextScale: 1.8
        )
        original.keybinds = [
            CommandPaletteKeyBinding(
                keystrokes: ["shift-cmd-y"],
                command: CommandPaletteCommandID.openSettings,
                when: .always,
                args: nil
            )
        ]
        original.equalizer = EqualizerSettings(
            enabled: true,
            preamp: -3,
            bands: [6, 3.5, 1, 0, -1, -2.5, -4, 0, 2, 4.5],
            activePresetName: nil,
            userPresets: [
                EqualizerPreset(name: "Warm", preamp: -1, bands: Array(repeating: 2, count: 10))
            ],
            forwardingTargetUID: "external-device"
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let validData = try encoder.encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: validData) as? [String: Any])
        var commandPalette = try XCTUnwrap(object["commandPalette"] as? [String: Any])
        commandPalette["backdropBlur"] = "not-a-boolean"
        object["commandPalette"] = commandPalette
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]).write(to: url)

        let store = SpotiglassSettingsStore(fileURL: url)

        XCTAssertEqual(store.settings.appearance, original.appearance)
        XCTAssertEqual(store.settings.keybinds, original.keybinds)
        XCTAssertEqual(store.settings.equalizer, original.equalizer)
        XCTAssertTrue(store.settings.commandPalette.backdropBlur, "The malformed field should use its field default")
        XCTAssertNil(store.lastError)

        let repairedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let repairedPalette = try XCTUnwrap(repairedObject["commandPalette"] as? [String: Any])
        XCTAssertEqual(repairedPalette["backdropBlur"] as? Bool, true)
        XCTAssertEqual(
            try JSONDecoder().decode(SpotiglassSettingsFile.self, from: Data(contentsOf: url)).appearance,
            original.appearance
        )
    }

    func testStagedSettingsMergeWithNewerExternalEdits() throws {
        let url = makeTempFileURL()
        let store = SpotiglassSettingsStore(fileURL: url)
        let externalKeybinds = [
            CommandPaletteKeyBinding(
                keystrokes: ["shift-cmd-y"],
                command: CommandPaletteCommandID.openSettings,
                when: .always,
                args: nil
            )
        ]

        store.stage { $0.appearance.lyricsTextScale = 2.2 }

        var external = try JSONDecoder().decode(
            SpotiglassSettingsFile.self,
            from: Data(contentsOf: url)
        )
        external.appearance.colorScheme = .dark
        external.equalizer.enabled = true
        external.keybinds = externalKeybinds
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(external).write(to: url, options: .atomic)

        try store.persistStagedSettings()

        let onDisk = try JSONDecoder().decode(SpotiglassSettingsFile.self, from: Data(contentsOf: url))
        XCTAssertEqual(onDisk.appearance.lyricsTextScale, 2.2)
        XCTAssertEqual(onDisk.appearance.colorScheme, .dark)
        XCTAssertTrue(onDisk.equalizer.enabled)
        XCTAssertEqual(onDisk.keybinds, externalKeybinds)
        XCTAssertEqual(store.settings, onDisk)
    }

    func testUpdateAppearanceColorSchemePersistsAtomically() throws {
        let url = makeTempFileURL()
        let store = SpotiglassSettingsStore(fileURL: url)

        try store.mutate { $0.appearance.colorScheme = .dark }

        XCTAssertEqual(store.settings.appearance.colorScheme, .dark)
        let onDisk = try JSONDecoder().decode(SpotiglassSettingsFile.self, from: try Data(contentsOf: url))
        XCTAssertEqual(onDisk.appearance.colorScheme, .dark)
    }

    func testEqualizerBypassStateReloadsWithoutFlatteningBands() throws {
        let url = makeTempFileURL()
        let store = SpotiglassSettingsStore(fileURL: url)
        let bands = [6.0, 3.5, 1.0, 0, -1.0, -2.5, -4.0, 0, 2.0, 4.5]

        try store.mutate { file in
            file.equalizer.enabled = false
            file.equalizer.bands = bands
            file.equalizer.activePresetName = nil
        }

        let reloaded = SpotiglassSettingsStore(fileURL: url)
        XCTAssertFalse(reloaded.settings.equalizer.enabled)
        XCTAssertEqual(reloaded.settings.equalizer.bands, bands)
        XCTAssertNil(reloaded.settings.equalizer.activePresetName)
    }

    func testUpdateKeybindsReplacesSliceOnly() throws {
        let url = makeTempFileURL()
        let store = SpotiglassSettingsStore(fileURL: url)
        let originalAppearance = store.settings.appearance

        let newKeybinds: [CommandPaletteKeyBinding] = [
            CommandPaletteKeyBinding(
                keystrokes: ["shift-cmd-y"],
                command: CommandPaletteCommandID.openSettings,
                when: .always,
                args: nil
            ),
        ]
        try store.updateKeybinds(newKeybinds)

        XCTAssertEqual(store.settings.keybinds, newKeybinds)
        XCTAssertEqual(store.settings.appearance, originalAppearance)
    }

    func testInvalidFileFallsBackToDefaultsAndRecordsError() throws {
        let url = makeTempFileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{not valid json".write(to: url, atomically: true, encoding: .utf8)

        let store = SpotiglassSettingsStore(fileURL: url)
        XCTAssertNotNil(store.lastError)
        XCTAssertFalse(store.settings.keybinds.isEmpty, "Defaults should be used when file is invalid")

        // The store should have rewritten the file with valid defaults.
        let recovered = try JSONDecoder().decode(SpotiglassSettingsFile.self, from: try Data(contentsOf: url))
        XCTAssertEqual(recovered.version, SpotiglassSettingsFile.currentVersion)
    }

    func testDefaultFileURLIsApplicationSupportSpotiglassSettingsJSON() {
        let url = SpotiglassSettingsStore.defaultFileURL(fileManager: .default)
        XCTAssertEqual(url.lastPathComponent, "settings.json")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Spotiglass")
        XCTAssertEqual(
            url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
            "Application Support"
        )
    }

    func testMigratesLegacyConfigToNewLocation() throws {
        let root = makeTempDir()
        let legacy = root.appendingPathComponent("config/spotiglass/settings.json")
        let destination = root.appendingPathComponent("ApplicationSupport/Spotiglass/settings.json")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = #"{"version":1}"#
        try payload.write(to: legacy, atomically: true, encoding: .utf8)

        SpotiglassSettingsStore.migrateLegacyConfigIfNeeded(fileManager: .default, from: legacy, to: destination)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "Legacy file should be moved, not copied")
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), payload)
    }

    func testMigrationNeverOverwritesExistingSettings() throws {
        let root = makeTempDir()
        let legacy = root.appendingPathComponent("config/settings.json")
        let destination = root.appendingPathComponent("dest/settings.json")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "legacy".write(to: legacy, atomically: true, encoding: .utf8)
        try "current".write(to: destination, atomically: true, encoding: .utf8)

        SpotiglassSettingsStore.migrateLegacyConfigIfNeeded(fileManager: .default, from: legacy, to: destination)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "current", "Existing settings must win")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path), "Legacy file is left intact when not migrating")
    }

    // MARK: - Helpers

    func testReloadFromDiskPicksUpExternalEdit() throws {
        let url = makeTempFileURL()
        let store = SpotiglassSettingsStore(fileURL: url)
        try store.mutate { $0.appearance.colorScheme = .light }
        XCTAssertEqual(store.settings.appearance.colorScheme, .light)

        var onDisk = try JSONDecoder().decode(SpotiglassSettingsFile.self, from: Data(contentsOf: url))
        onDisk.appearance.colorScheme = .dark
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(onDisk).write(to: url, options: .atomic)

        store.reloadFromDisk()
        XCTAssertEqual(store.settings.appearance.colorScheme, .dark)
        XCTAssertNil(store.lastError)
    }

    func testApplyLoadedSettingsStripsLegacyRefreshTracksBinding() throws {
        let url = makeTempFileURL()
        let legacy = CommandPaletteKeyBinding(
            keystrokes: ["cmd-t"],
            command: CommandPaletteCommandID.refreshTracks,
            when: .always,
            args: nil
        )
        let file = SpotiglassSettingsFile(
            keybinds: SpotiglassSettingsStore.defaultKeybinds() + [legacy],
            appearance: AppearanceSettings(colorScheme: .system),
            commandPalette: CommandPaletteSettings(backdropBlur: true)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(file).write(to: url)

        let store = SpotiglassSettingsStore(fileURL: url)
        XCTAssertFalse(store.settings.keybinds.contains { $0.command == CommandPaletteCommandID.refreshTracks })
        let onDisk = try JSONDecoder().decode(SpotiglassSettingsFile.self, from: Data(contentsOf: url))
        XCTAssertFalse(onDisk.keybinds.contains { $0.command == CommandPaletteCommandID.refreshTracks })
    }

    func testLoadSeedsDefaultBindingForCommandAddedAfterFileWasWritten() throws {
        // Simulates a settings.json written before palette.enqueue existed: the command
        // has neither a binding nor a seeded-list entry, so its ⇧↩ default must be added.
        let url = makeTempFileURL()
        let oldKeybinds = SpotiglassSettingsStore.defaultKeybinds()
            .filter { $0.command != CommandPaletteCommandID.enqueueSelected }
        let file = SpotiglassSettingsFile(keybinds: oldKeybinds)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(file).write(to: url)

        let store = SpotiglassSettingsStore(fileURL: url)

        let seeded = store.settings.keybinds.first { $0.command == CommandPaletteCommandID.enqueueSelected }
        XCTAssertEqual(seeded?.keystrokes, ["shift-return"])
        XCTAssertEqual(seeded?.when, .paletteOpen)
        XCTAssertTrue(store.settings.seededKeybindCommands.contains(CommandPaletteCommandID.enqueueSelected))
        let onDisk = try JSONDecoder().decode(SpotiglassSettingsFile.self, from: Data(contentsOf: url))
        XCTAssertTrue(onDisk.keybinds.contains { $0.command == CommandPaletteCommandID.enqueueSelected })
    }

    func testLoadDoesNotResurrectBindingTheUserCleared() throws {
        let url = makeTempFileURL()
        var file = SpotiglassSettingsStore.bootstrapDefaults()
        file.keybinds.removeAll { $0.command == CommandPaletteCommandID.enqueueSelected }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(file).write(to: url)

        let store = SpotiglassSettingsStore(fileURL: url)

        XCTAssertFalse(store.settings.keybinds.contains { $0.command == CommandPaletteCommandID.enqueueSelected })
    }

    func testLoadSkipsSeedingWhenDefaultShortcutIsTakenByUserBinding() throws {
        let url = makeTempFileURL()
        // User had rebound palette.pin to ⇧↩ before the enqueue command existed.
        var oldKeybinds = SpotiglassSettingsStore.defaultKeybinds().filter {
            $0.command != CommandPaletteCommandID.enqueueSelected
                && $0.command != CommandPaletteCommandID.pinSelected
        }
        oldKeybinds.append(
            CommandPaletteKeyBinding(
                keystrokes: ["shift-return"],
                command: CommandPaletteCommandID.pinSelected,
                when: .paletteOpen,
                args: nil
            )
        )
        let file = SpotiglassSettingsFile(keybinds: oldKeybinds)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(file).write(to: url)

        let store = SpotiglassSettingsStore(fileURL: url)

        XCTAssertFalse(store.settings.keybinds.contains { $0.command == CommandPaletteCommandID.enqueueSelected })
        XCTAssertTrue(
            store.settings.seededKeybindCommands.contains(CommandPaletteCommandID.enqueueSelected),
            "Skipped commands must still be marked seeded so they are not retried every launch"
        )
    }

    private func makeTempFileURL() -> URL {
        makeTempDir().appendingPathComponent("settings.json", isDirectory: false)
    }

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpotiglassSettingsStoreTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }
}
