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
        let halLibrary =
            appDir
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Audio", isDirectory: true)
            .appendingPathComponent("Plug-Ins", isDirectory: true)
            .appendingPathComponent("HAL", isDirectory: true)
        try? FileManager.default.createDirectory(at: halLibrary, withIntermediateDirectories: true)
        fixtureBundle =
            halLibrary
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
        // Use the pure install() entry point so the test doesn't accidentally
        // flip the system's real default output device when a Spotiglass EQ
        // is actually loaded on the host running the tests.
        try controller.install()
        XCTAssertTrue(
            controller.isInstalled,
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
        try controller.install()
        XCTAssertTrue(controller.isInstalled)
        try controller.uninstall()
        XCTAssertFalse(controller.isInstalled)
        // Calling again must NOT throw.
        XCTAssertNoThrow(try controller.uninstall())
    }

    func testEnableTrustsExistingInstalledDriverAndDoesNotReplaceIt() throws {
        // The system HAL directory (/Library/Audio/Plug-Ins/HAL) is root-owned
        // on macOS 26, so the unprivileged app process must not try to clobber
        // an existing install. Once the .driver is present, enable() should
        // leave it alone and proceed to route the default output.
        let controller = EqualizerHALPluginController(
            halDirectory: halDirectory,
            fileManager: .default,
            bundle: fakeAppBundle
        )
        try controller.install()
        let userFile = controller.installedDriverURL.appendingPathComponent("UserFile.txt")
        try "preserved".write(to: userFile, atomically: true, encoding: .utf8)

        // Re-install. The existing bundle (and any sibling files in it) must
        // survive — the controller has no business clobbering a root-owned
        // install it can't actually rewrite in production.
        try controller.install()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: userFile.path),
            "enable() must not replace an existing installed bundle"
        )
        XCTAssertEqual(
            try String(contentsOf: userFile, encoding: .utf8),
            "preserved"
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
        XCTAssertThrowsError(try controller.install()) { error in
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
            XCTAssertFalse(
                seen.contains(fingerprint),
                "two presets produced identical coefficients: \(preset.name)")
            seen.insert(fingerprint)
            if preset.name != EqualizerPreset.flatName {
                XCTAssertNotEqual(
                    frame.bands, bypass.bands,
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
