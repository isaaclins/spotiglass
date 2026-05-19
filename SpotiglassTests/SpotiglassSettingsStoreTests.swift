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
        let original = SpotiglassSettingsFile(
            keybinds: SpotiglassSettingsStore.defaultKeybinds(),
            appearance: AppearanceSettings(colorScheme: .dark),
            commandPalette: CommandPaletteSettings(backdropBlur: false)
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
