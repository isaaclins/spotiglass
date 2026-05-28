import XCTest
@testable import Spotiglass

/// Exercises ``EqualizerHALPluginController`` against a temp HAL directory so
/// tests never touch the user's real `~/Library/Audio/Plug-Ins/HAL/`. The
/// .driver bundle that lives inside `Spotiglass.app` isn't built by an Xcode
/// target yet (see docs/equalizer.md "Known limitations"); these tests stage
/// a minimal `.driver` fixture in a temp directory so install/uninstall and
/// idempotency are still verifiable.
final class EqualizerHALPluginTests: XCTestCase {
    private var halDirectory: URL!
    private var fixtureBundle: URL!
    private var fakeAppBundle: Bundle!

    override func setUp() {
        super.setUp()
        halDirectory = makeTempDirectory()
        // Build a fake .driver bundle in a sibling temp dir so the controller
        // can locate it via Bundle.bundleURL/Contents/Library/Audio/Plug-Ins/HAL.
        let appDir = makeTempDirectory()
        let halLibrary = appDir
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Audio", isDirectory: true)
            .appendingPathComponent("Plug-Ins", isDirectory: true)
            .appendingPathComponent("HAL", isDirectory: true)
        try? FileManager.default.createDirectory(at: halLibrary, withIntermediateDirectories: true)
        fixtureBundle = halLibrary
            .appendingPathComponent(EqualizerHALPluginController.driverBundleName, isDirectory: true)
        try? FileManager.default.createDirectory(at: fixtureBundle, withIntermediateDirectories: true)
        try? "fake-driver-payload".write(
            to: fixtureBundle.appendingPathComponent("Marker.txt"),
            atomically: true,
            encoding: .utf8
        )
        fakeAppBundle = Bundle(url: appDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: halDirectory)
        super.tearDown()
    }

    // MARK: - Install / uninstall

    func testInstallCopiesEmbeddedDriverIntoHALDirectory() throws {
        let controller = EqualizerHALPluginController(
            halDirectory: halDirectory,
            fileManager: .default,
            bundle: fakeAppBundle
        )
        XCTAssertFalse(controller.isInstalled)
        // enable() also tries to flip the system default output; under test we
        // expect the lookup to return nil (no actual coreaudiod device named
        // "Spotiglass EQ") and the controller to surface driverNotLoadedYet.
        XCTAssertThrowsError(try controller.enable()) { error in
            guard case EqualizerHALPluginError.driverNotLoadedYet = error else {
                return XCTFail("expected driverNotLoadedYet, got \(error)")
            }
        }
        XCTAssertTrue(controller.isInstalled,
                      "the .driver should be copied even when coreaudiod hasn't picked it up")
        let marker = controller.installedDriverURL.appendingPathComponent("Marker.txt")
        XCTAssertEqual(
            try String(contentsOf: marker, encoding: .utf8),
            "fake-driver-payload"
        )
    }

    func testUninstallRemovesDirectoryAndIsIdempotent() throws {
        let controller = EqualizerHALPluginController(
            halDirectory: halDirectory,
            fileManager: .default,
            bundle: fakeAppBundle
        )
        // Stage an install first.
        _ = try? controller.enable()
        XCTAssertTrue(controller.isInstalled)
        try controller.uninstall()
        XCTAssertFalse(controller.isInstalled)
        // Calling again must NOT throw.
        XCTAssertNoThrow(try controller.uninstall())
    }

    func testInstallReplacesPreviousDriverInPlace() throws {
        let controller = EqualizerHALPluginController(
            halDirectory: halDirectory,
            fileManager: .default,
            bundle: fakeAppBundle
        )
        _ = try? controller.enable()
        let stalePath = controller.installedDriverURL.appendingPathComponent("StaleFile.txt")
        try "stale".write(to: stalePath, atomically: true, encoding: .utf8)

        // Re-install. The previous bundle (including StaleFile.txt) should be
        // removed and replaced with a fresh copy of the embedded source.
        _ = try? controller.enable()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stalePath.path),
            "re-install must clear the old bundle's contents"
        )
    }

    // MARK: - Error surfaces

    func testEnableSurfacesEmbeddedDriverMissingWhenBundleHasNoPayload() {
        let emptyAppBundle = Bundle(url: makeTempDirectory())!
        let controller = EqualizerHALPluginController(
            halDirectory: halDirectory,
            fileManager: .default,
            bundle: emptyAppBundle
        )
        XCTAssertThrowsError(try controller.enable()) { error in
            guard case EqualizerHALPluginError.embeddedDriverMissing = error else {
                return XCTFail("expected embeddedDriverMissing, got \(error)")
            }
        }
    }

    // MARK: - Built-in preset → coefficient frame round-trip

    func testAllSevenBuiltInPresetsProduceUniqueCoefficientFrames() {
        // Confirms `EqualizerPreset.builtIns` is wired to coefficient
        // generation correctly: each preset (except Flat) produces a frame
        // distinguishable from the bypass identity.
        let bypass = EQCoefficientFrame.bypass(sampleRateHz: 48_000)
        var seen: Set<String> = []
        for preset in EqualizerPreset.builtIns {
            var settings = EqualizerSettings()
            settings.apply(preset: preset)
            let frame = EQCoefficientFrame.build(settings: settings, sampleRateHz: 48_000)
            let fingerprint = frame.bands.map { String(format: "%.4f", $0) }.joined(separator: ",")
            XCTAssertFalse(seen.contains(fingerprint),
                           "two presets produced identical coefficients: \(preset.name)")
            seen.insert(fingerprint)
            if preset.name != EqualizerPreset.flatName {
                XCTAssertNotEqual(frame.bands, bypass.bands,
                                  "\(preset.name) should differ from bypass")
            }
        }
    }

    // MARK: - Helpers

    private func makeTempDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("spotiglass-eq-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
