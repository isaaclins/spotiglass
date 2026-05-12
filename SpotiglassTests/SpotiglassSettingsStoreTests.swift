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
        XCTAssertFalse(store.settings.equalizer.enabled)
        XCTAssertEqual(store.settings.equalizer.bands.count, EqualizerSettings.bandCount)
        XCTAssertTrue(store.settings.commandPalette.backdropBlur)
        XCTAssertEqual(store.settings.appearance.colorScheme, .system)
        XCTAssertFalse(store.settings.keybinds.isEmpty)
    }

    func testRoundTripPreservesKeybindsEqualizerAndPresets() throws {
        let url = makeTempFileURL()
        let original = SpotiglassSettingsFile(
            keybinds: SpotiglassSettingsStore.defaultKeybinds(),
            equalizer: EqualizerSettings(
                enabled: true,
                preamp: -3,
                bands: [4, 3, 2, 1, 0, -1, -2, -3, -4, -5],
                activePresetName: "Custom 1",
                userPresets: [
                    EqualizerPreset(name: "Custom 1", preamp: -3, bands: [4, 3, 2, 1, 0, -1, -2, -3, -4, -5]),
                ]
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(original).write(to: url)

        let store = SpotiglassSettingsStore(fileURL: url)
        XCTAssertEqual(store.settings, original)
    }

    func testUpdateAppearanceColorSchemePersistsAtomically() throws {
        let url = makeTempFileURL()
        let store = SpotiglassSettingsStore(fileURL: url)

        try store.mutate { $0.appearance.colorScheme = .dark }

        XCTAssertEqual(store.settings.appearance.colorScheme, .dark)
        let onDisk = try JSONDecoder().decode(SpotiglassSettingsFile.self, from: try Data(contentsOf: url))
        XCTAssertEqual(onDisk.appearance.colorScheme, .dark)
    }

    func testUpdateEqualizerPersistsAtomically() throws {
        let url = makeTempFileURL()
        let store = SpotiglassSettingsStore(fileURL: url)

        var equalizer = store.settings.equalizer
        equalizer.enabled = true
        equalizer.bands = [6, 5, 3, 1, 0, 0, 0, 0, 0, 0]
        equalizer.activePresetName = "Bass Boost"
        try store.mutate { $0.equalizer = equalizer }

        let onDisk = try JSONDecoder().decode(SpotiglassSettingsFile.self, from: try Data(contentsOf: url))
        XCTAssertTrue(onDisk.equalizer.enabled)
        XCTAssertEqual(onDisk.equalizer.bands, [6, 5, 3, 1, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(onDisk.equalizer.activePresetName, "Bass Boost")
    }

    func testUpdateKeybindsReplacesSliceOnly() throws {
        let url = makeTempFileURL()
        let store = SpotiglassSettingsStore(fileURL: url)
        let originalEqualizer = store.settings.equalizer

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
        XCTAssertEqual(store.settings.equalizer, originalEqualizer)
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

    func testUserPresetsSurviveSave() throws {
        let url = makeTempFileURL()
        let store = SpotiglassSettingsStore(fileURL: url)

        let preset = EqualizerPreset(
            name: "Late Night",
            preamp: -2,
            bands: [-3, -2, -1, 0, 1, 1, 0, -1, -2, -3]
        )
        try store.mutate { file in
            file.equalizer.userPresets = [preset]
            file.equalizer.activePresetName = preset.name
            file.equalizer.bands = preset.bands
            file.equalizer.preamp = preset.preamp
        }

        let onDisk = try JSONDecoder().decode(SpotiglassSettingsFile.self, from: try Data(contentsOf: url))
        XCTAssertEqual(onDisk.equalizer.userPresets, [preset])
        XCTAssertEqual(onDisk.equalizer.activePresetName, "Late Night")
    }

    func testDefaultFileURLIsConfigSpotiglassSettingsJSON() {
        let url = SpotiglassSettingsStore.defaultFileURL(fileManager: .default)
        XCTAssertEqual(url.lastPathComponent, "settings.json")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "spotiglass")
        XCTAssertEqual(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, ".config")
    }

    // MARK: - Helpers

    private func makeTempFileURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpotiglassSettingsStoreTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
        }
        return dir.appendingPathComponent("settings.json", isDirectory: false)
    }
}
