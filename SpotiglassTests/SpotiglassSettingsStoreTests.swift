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
        XCTAssertEqual(decoded.version, SpotiglassSettingsFile.legacyVersion)
        XCTAssertEqual(
            decoded.keybindSeedBaselineVersion,
            SpotiglassSettingsFile.legacyKeybindSeedBaselineVersion
        )
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

    func testOutOfRangeEqualizerPreampClampsOnDecode() throws {
        func decodePreamp(_ raw: Double) throws -> Double {
            let json = """
            { "keybinds" : [], "equalizer" : { "preamp" : \(raw) } }
            """
            return try JSONDecoder()
                .decode(SpotiglassSettingsFile.self, from: Data(json.utf8))
                .equalizer.preamp
        }
        XCTAssertEqual(try decodePreamp(100.0), EqualizerSettings.preampRangeDB.upperBound)
        XCTAssertEqual(try decodePreamp(-100.0), EqualizerSettings.preampRangeDB.lowerBound)
        XCTAssertEqual(try decodePreamp(3.5), 3.5)
    }

    func testOutOfRangeEqualizerPreampIsWrittenBackClamped() throws {
        let url = makeTempFileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        { "keybinds" : [], "equalizer" : { "preamp" : 100 } }
        """.utf8).write(to: url)

        let store = SpotiglassSettingsStore(fileURL: url)

        XCTAssertEqual(store.settings.equalizer.preamp, EqualizerSettings.preampRangeDB.upperBound)
        XCTAssertNil(store.lastError)
        // Read the raw number: decoding would clamp again and hide a stale file.
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let equalizer = try XCTUnwrap(object["equalizer"] as? [String: Any])
        XCTAssertEqual(
            try XCTUnwrap(equalizer["preamp"] as? Double),
            EqualizerSettings.preampRangeDB.upperBound,
            "A clamped value is a repair, so the document should be rewritten in range"
        )
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

    // MARK: - Files the store can't fully read (#597)

    /// A settings.json cut off mid-write (a sync tool, an editor crash) used to be replaced by
    /// the defaults with no copy. The bytes now survive next to it, and Settings names the copy.
    func testTruncatedSettingsFileIsKeptAsACopyBeforeDefaultsAreSaved() throws {
        let url = makeTempFileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"version":1,"keybinds":["#.utf8)
        try original.write(to: url)

        let store = SpotiglassSettingsStore(fileURL: url)

        let copies = UnreadableFileBackup.copies(of: url)
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(copies.first)), original)
        XCTAssertFalse(store.settings.keybinds.isEmpty, "Defaults should be used when file is invalid")
        let recovered = try JSONDecoder().decode(SpotiglassSettingsFile.self, from: try Data(contentsOf: url))
        XCTAssertEqual(recovered.version, SpotiglassSettingsFile.currentVersion)
        XCTAssertEqual(store.backupURL, copies.first)
        XCTAssertTrue(try XCTUnwrap(store.backupNotice?.string).contains(XCTUnwrap(copies.first?.lastPathComponent)))
    }

    /// A hand edit with a syntax error while the app runs: the reload keeps the settings in use,
    /// and the next change in the app used to write over the half-finished edit.
    func testBrokenHandEditIsKeptAsACopyBeforeTheNextChangeInTheApp() throws {
        let url = makeTempFileURL()
        let store = SpotiglassSettingsStore(fileURL: url)
        let edit = Data(#"{"version":2,"appearance":{"colorScheme":"dark",}"#.utf8)
        try edit.write(to: url)
        store.reloadFromDisk()
        XCTAssertNotNil(store.lastError, "Settings says the file can't be read right now")

        try store.mutate { $0.appearance.lyricsTextSize = .large }
        XCTAssertNil(store.lastError, "once the copy is kept and the file saved, only the copy is named")
        XCTAssertNotNil(store.backupNotice)

        let copies = UnreadableFileBackup.copies(of: url)
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(copies.first)), edit)
        let saved = try JSONDecoder().decode(SpotiglassSettingsFile.self, from: try Data(contentsOf: url))
        XCTAssertEqual(saved.appearance.lyricsTextSize, .large)
    }

    /// One unreadable keybind row is skipped and its siblings stay; the file as it was is
    /// copied before the repaired one replaces it, and the repair names the row.
    func testUnreadableRowIsSkippedAndTheFileIsCopiedBeforeTheRepairIsSaved() throws {
        let url = makeTempFileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"""
        {"version":2,"keybindSeedBaselineVersion":1,"seededKeybindCommands":[],
         "keybinds":[{"keystrokes":["shift-cmd-9"],"command":"app.openSettings","when":"always"},
                     {"keystrokes":["cmd-j"],"command":"x","when":"somewhereNew"}]}
        """#.utf8)
        try original.write(to: url)

        let store = SpotiglassSettingsStore(fileURL: url)

        XCTAssertTrue(store.settings.keybinds.contains { $0.keystrokes == ["shift-cmd-9"] && $0.command == "app.openSettings" })
        let copies = UnreadableFileBackup.copies(of: url)
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(copies.first)), original)

        let tracker = SpotiglassSettingsDecodeTracker()
        let decoder = JSONDecoder()
        decoder.userInfo[.spotiglassSettingsDecodeTracker] = tracker
        _ = try decoder.decode(SpotiglassSettingsFile.self, from: original)
        XCTAssertEqual(tracker.repairs.count, 1)
        XCTAssertTrue(tracker.repairs[0].hasPrefix("keybinds[1]"), tracker.repairs[0])
    }

    /// A file that can't even be read (no permission) is never replaced: the app runs on the
    /// defaults, each save fails visibly, and the file is untouched.
    func testSettingsFileThatCantBeReadIsNeverWrittenOver() throws {
        let url = makeTempFileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"version":2,"appearance":{"colorScheme":"dark"}}"#.utf8)
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }

        let store = SpotiglassSettingsStore(fileURL: url)
        XCTAssertNotNil(store.lastError, "Settings says the file can't be read")
        XCTAssertNil(store.saveFailure, "nothing was saved yet, so nothing failed to save")
        XCTAssertThrowsError(try store.mutate { $0.appearance.colorScheme = .light })
        XCTAssertNotNil(store.saveFailure)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertTrue(UnreadableFileBackup.copies(of: url).isEmpty)
    }

    /// The file can't be read at launch and is readable again later (permissions fixed): the
    /// next change in the app goes into the real settings instead of the defaults replacing them.
    func testFileThatBecomesReadableAgainKeepsItsSettingsOnTheNextChange() throws {
        let url = makeTempFileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var mine = SpotiglassSettingsStore.bootstrapDefaults()
        mine.appearance.colorScheme = .dark
        mine.appearance.lyricsTextSize = .large
        mine.equalizer.preamp = -3
        try JSONEncoder().encode(mine).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }

        let store = SpotiglassSettingsStore(fileURL: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try store.mutate { $0.appearance.colorScheme = .light }

        let saved = try JSONDecoder().decode(SpotiglassSettingsFile.self, from: try Data(contentsOf: url))
        XCTAssertEqual(saved.appearance.colorScheme, .light)
        XCTAssertEqual(saved.appearance.lyricsTextSize, .large, "the real settings were replaced by the defaults")
        XCTAssertEqual(saved.equalizer.preamp, -3)
        XCTAssertEqual(store.settings.appearance.lyricsTextSize, .large)
    }

    /// Settings folder not writable: a change used to fail silently (`try?` in the pane, no log).
    /// The store now says so, for Appearance and for deleting an equalizer preset alike.
    func testSaveIntoAFolderThatCantBeWrittenIsReported() throws {
        let url = makeTempFileURL()
        var file = SpotiglassSettingsStore.bootstrapDefaults()
        file.equalizer.userPresets = [EqualizerPreset(name: "Mine", bands: Array(repeating: 1, count: EqualizerSettings.bandCount))]
        file.equalizer.activePresetName = "Mine"
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(file).write(to: url)
        let store = SpotiglassSettingsStore(fileURL: url)
        XCTAssertNil(store.saveFailure)
        let folder = url.deletingLastPathComponent().path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }

        store.update { $0.appearance.colorScheme = .dark }
        XCTAssertNotNil(store.saveFailure)

        store.update { file in
            file.equalizer.userPresets.removeAll { $0.name == "Mine" }
            file.equalizer.activePresetName = nil
        }
        XCTAssertNotNil(store.saveFailure)
        XCTAssertEqual(store.settings.equalizer.userPresets.map(\.name), ["Mine"], "Nothing pretends it was saved")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder)
        store.update { $0.appearance.colorScheme = .dark }
        XCTAssertNil(store.saveFailure, "The next save that works clears it")
    }

    /// A damaged file in a folder the copy can't be written to stays as it is: no copy, no save.
    func testDamagedFileIsNotReplacedWhenNoCopyCanBeMade() throws {
        let url = makeTempFileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{".utf8)
        try original.write(to: url)
        let folder = url.deletingLastPathComponent().path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }

        let store = SpotiglassSettingsStore(fileURL: url)

        XCTAssertNotNil(store.saveFailure)
        XCTAssertNil(store.backupNotice)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    /// Dotfiles: a symlinked settings.json used to become a plain file on the first save.
    func testSymlinkedSettingsFileStaysALinkAndItsTargetIsUpdated() throws {
        let dotfiles = makeTempDir()
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let target = dotfiles.appendingPathComponent("settings.json")
        try JSONEncoder().encode(SpotiglassSettingsStore.bootstrapDefaults()).write(to: target)
        let url = makeTempFileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)

        let store = SpotiglassSettingsStore(fileURL: url)
        try store.mutate { $0.appearance.colorScheme = .dark }

        let type = try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeSymbolicLink)
        let saved = try JSONDecoder().decode(SpotiglassSettingsFile.self, from: try Data(contentsOf: target))
        XCTAssertEqual(saved.appearance.colorScheme, .dark)
    }

    /// Moving a relative symlink from ~/.config into Application Support used to break it.
    func testMigrationKeepsASymlinkedLegacyFilePointingAtItsTarget() throws {
        let root = makeTempDir()
        let dotfiles = root.appendingPathComponent("dotfiles", isDirectory: true)
        let legacyDir = root.appendingPathComponent("config/spotiglass", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        let target = dotfiles.appendingPathComponent("settings.json")
        try Data(#"{"version":2}"#.utf8).write(to: target)
        let legacy = legacyDir.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(atPath: legacy.path, withDestinationPath: "../../dotfiles/settings.json")
        let newURL = root.appendingPathComponent("Application Support/Spotiglass/settings.json")

        SpotiglassSettingsStore.migrateLegacyConfigIfNeeded(fileManager: .default, from: legacy, to: newURL)

        let type = try FileManager.default.attributesOfItem(atPath: newURL.path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeSymbolicLink)
        XCTAssertEqual(try Data(contentsOf: newURL), try Data(contentsOf: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testCopiesAreMadeOncePerContentAndOnlyTheNewestAreKept() throws {
        let dir = makeTempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.json")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try UnreadableFileBackup.preserve(Data("a".utf8), of: url, now: start)
        XCTAssertEqual(try UnreadableFileBackup.preserve(Data("a".utf8), of: url, now: start.addingTimeInterval(60)), first)

        for step in 1...7 {
            try UnreadableFileBackup.preserve(Data("v\(step)".utf8), of: url, now: start.addingTimeInterval(Double(step)))
        }
        // Two in the same second get a counter instead of replacing each other.
        try UnreadableFileBackup.preserve(Data("same second".utf8), of: url, now: start.addingTimeInterval(7))

        let kept = UnreadableFileBackup.copies(of: url)
        XCTAssertEqual(kept.count, UnreadableFileBackup.keptCopies)
        XCTAssertEqual(try kept.map { String(decoding: try Data(contentsOf: $0), as: UTF8.self) }, ["v4", "v5", "v6", "v7", "same second"])
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
        // Simulates a current-schema file written before palette.enqueue existed: the
        // command has neither a binding nor a seeded-list entry, so its ⇧↩ default must
        // be added. The explicit empty metadata is intentionally different from a
        // pre-metadata file, whose legacy baseline is tested below.
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

    func testPreMetadataFixturePreservesClearedLegacyCommandAndSeedsNewCommand() throws {
        // This is the shape written before seededKeybindCommands existed. The missing
        // palette.enqueue row is deliberate: it was an old command the user cleared,
        // not a command that was added after this file was created.
        let legacyJSON = """
        {
          "version" : 1,
          "keybinds" : [
            { "keystrokes" : ["cmd-,"], "command" : "app.openSettings", "when" : "always" }
          ],
          "appearance" : { "colorScheme" : "dark" },
          "commandPalette" : { "backdropBlur" : false },
          "equalizer" : { }
        }
        """
        let url = makeTempFileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try legacyJSON.write(to: url, atomically: true, encoding: .utf8)

        let decoded = try JSONDecoder().decode(SpotiglassSettingsFile.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(
            decoded.keybindSeedBaselineVersion,
            SpotiglassSettingsFile.legacyKeybindSeedBaselineVersion
        )

        let store = SpotiglassSettingsStore(fileURL: url)

        XCTAssertFalse(
            store.settings.keybinds.contains { $0.command == CommandPaletteCommandID.enqueueSelected },
            "A cleared command from the pre-metadata catalog must stay cleared"
        )
        XCTAssertTrue(
            store.settings.keybinds.contains { $0.command == CommandPaletteCommandID.openSearch },
            "A command added after the legacy baseline should still receive its default"
        )
        XCTAssertEqual(store.settings.appearance.colorScheme, .dark)
        XCTAssertFalse(store.settings.commandPalette.backdropBlur)

        let onDisk = try JSONDecoder().decode(SpotiglassSettingsFile.self, from: Data(contentsOf: url))
        XCTAssertEqual(onDisk.version, SpotiglassSettingsFile.currentVersion)
        XCTAssertEqual(
            onDisk.keybindSeedBaselineVersion,
            SpotiglassSettingsFile.currentKeybindSeedBaselineVersion
        )
        XCTAssertTrue(onDisk.seededKeybindCommands.contains(CommandPaletteCommandID.enqueueSelected))
        XCTAssertFalse(onDisk.keybinds.contains { $0.command == CommandPaletteCommandID.enqueueSelected })
    }

    func testExplicitEmptySeedMetadataDoesNotUseLegacyBaseline() throws {
        let url = makeTempFileURL()
        let explicitEmptyJSON = """
        {
          "version" : 1,
          "keybinds" : [],
          "seededKeybindCommands" : [],
          "appearance" : { },
          "commandPalette" : { },
          "equalizer" : { }
        }
        """
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try explicitEmptyJSON.write(to: url, atomically: true, encoding: .utf8)

        let store = SpotiglassSettingsStore(fileURL: url)

        XCTAssertTrue(
            store.settings.keybinds.contains { $0.command == CommandPaletteCommandID.enqueueSelected },
            "An explicit empty tracked list means every current default is eligible for seeding"
        )
        XCTAssertEqual(
            store.settings.keybindSeedBaselineVersion,
            SpotiglassSettingsFile.currentKeybindSeedBaselineVersion
        )
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

    /// Releasing a store closed its watcher's descriptor twice: once in `deinit` and once more in
    /// the watcher's cancel handler on the main queue. Whatever opened a file in between got the
    /// freed number and lost its file to the second close; under the test host that was a WebKit
    /// descriptor guarded against it, and the process died with EXC_GUARD in the next test (#515).
    func testReleasingAStoreClosesOnlyItsOwnDescriptor() throws {
        let url = makeTempFileURL()
        var store: SpotiglassSettingsStore? = SpotiglassSettingsStore(fileURL: url)
        XCTAssertNotNil(store)
        // The watcher is the descriptor open on the settings file itself, whatever else the test
        // host's other threads open meanwhile.
        let watcher = try XCTUnwrap(Self.descriptor(openOn: url), "the store watches no file")

        store = nil
        // Opened before the cancel handler has run, like WebKit's descriptor was: the lowest free
        // number from the watcher's up, which is the watcher's own once it has been closed.
        var other = open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(other, 0)
        if other < watcher {
            let lower = other
            other = fcntl(lower, F_DUPFD, watcher)
            close(lower)
        }
        XCTAssertGreaterThanOrEqual(other, 0)
        defer { close(other) }
        // The cancel handler runs on the main queue; it has run once the watcher's number no
        // longer refers to the settings file. On main that close hit `other`, which had taken it.
        // However late a busy machine runs it (#535).
        _ = AppKitTestSupport.pumpRunLoop(until: {
            !Self.descriptor(watcher, isOpenOn: url) && !(other == watcher && fcntl(other, F_GETFD) != -1)
        })

        XCTAssertFalse(Self.descriptor(watcher, isOpenOn: url), "the released store left its watcher's descriptor open")
        XCTAssertNotEqual(fcntl(other, F_GETFD), -1, "the released store closed descriptor \(other), which it no longer owned")
    }

    private static func descriptor(openOn url: URL) -> Int32? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []
        return names.compactMap(Int32.init).filter { descriptor($0, isOpenOn: url) }.min()
    }

    /// Whether `descriptor` is open on the file at `url` (same device and inode).
    private static func descriptor(_ descriptor: Int32, isOpenOn url: URL) -> Bool {
        var opened = stat()
        var file = stat()
        guard fstat(descriptor, &opened) == 0, stat(url.path, &file) == 0 else { return false }
        return opened.st_dev == file.st_dev && opened.st_ino == file.st_ino
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
