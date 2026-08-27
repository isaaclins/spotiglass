import CoreAudio
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
    private var defaultOutputBackupURL: URL!
    private var fixtureBundle: URL!
    private var fakeAppBundle: Bundle!

    override func setUp() {
        super.setUp()
        halDirectory = makeTempDirectory()
        defaultOutputBackupURL = makeTempDirectory()
            .appendingPathComponent("eq-default-output.uid")
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
        EqualizerHALPluginController.clearForwardingTarget()
        try? FileManager.default.removeItem(at: halDirectory)
        try? FileManager.default.removeItem(at: defaultOutputBackupURL.deletingLastPathComponent())
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

    // MARK: - Durable pre-EQ output backup

    func testPersistedOutputUIDResolvesToTheCurrentIDAfterControllerRestart() throws {
        let uid = "ExternalUSBDevice"
        try EqualizerHALPluginController.writeDefaultOutputBackup(
            uid: uid,
            to: defaultOutputBackupURL
        )
        var restoredIDs: [AudioObjectID] = []
        let controller = EqualizerHALPluginController(
            defaultOutputBackupURL: defaultOutputBackupURL,
            outputDeviceIDForUID: { $0 == uid ? AudioObjectID(42) : nil },
            defaultOutputSetter: { restoredIDs.append($0) }
        )

        XCTAssertEqual(controller.previousDefaultOutputUID, uid)
        try controller.restorePreviousDefaultOutput()
        XCTAssertEqual(restoredIDs, [AudioObjectID(42)])
        XCTAssertEqual(controller.previousDefaultOutputID, AudioObjectID(42))
    }

    func testDisableRestoresPersistedOutputAndClearsItsBackup() throws {
        let uid = "AirPodsMaxUID"
        try EqualizerHALPluginController.writeDefaultOutputBackup(
            uid: uid,
            to: defaultOutputBackupURL
        )
        var restoredIDs: [AudioObjectID] = []
        let controller = EqualizerHALPluginController(
            defaultOutputBackupURL: defaultOutputBackupURL,
            outputDeviceIDForUID: { $0 == uid ? AudioObjectID(73) : nil },
            defaultOutputSetter: { restoredIDs.append($0) }
        )

        try controller.disable()

        XCTAssertEqual(restoredIDs, [AudioObjectID(73)])
        XCTAssertNil(controller.previousDefaultOutputUID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultOutputBackupURL.path))
    }

    func testRestoreReportsWhenPersistedOutputIsNoLongerPresent() throws {
        let uid = "DisconnectedUSBDevice"
        try EqualizerHALPluginController.writeDefaultOutputBackup(
            uid: uid,
            to: defaultOutputBackupURL
        )
        let controller = EqualizerHALPluginController(
            defaultOutputBackupURL: defaultOutputBackupURL,
            outputDeviceIDForUID: { _ in nil },
            defaultOutputSetter: { _ in XCTFail("setter must not run for a missing device") }
        )

        XCTAssertThrowsError(try controller.restorePreviousDefaultOutput()) { error in
            guard case let EqualizerHALPluginError.previousOutputDeviceUnavailable(foundUID) = error else {
                return XCTFail("expected previousOutputDeviceUnavailable, got \(error)")
            }
            XCTAssertEqual(foundUID, uid)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: defaultOutputBackupURL.path))
    }

    func testRestoreExposesASetterFailureThroughTheInjectedSeam() throws {
        let uid = "ExternalUSBDevice"
        try EqualizerHALPluginController.writeDefaultOutputBackup(
            uid: uid,
            to: defaultOutputBackupURL
        )
        let controller = EqualizerHALPluginController(
            defaultOutputBackupURL: defaultOutputBackupURL,
            outputDeviceIDForUID: { $0 == uid ? AudioObjectID(91) : nil },
            defaultOutputSetter: { _ in
                throw EqualizerHALPluginError.coreAudioStatus(-1)
            }
        )

        XCTAssertThrowsError(try controller.restorePreviousDefaultOutput()) { error in
            guard case EqualizerHALPluginError.previousOutputRestoreFailed(underlying: let underlying) = error else {
                return XCTFail("expected previousOutputRestoreFailed, got \(error)")
            }
            guard case EqualizerHALPluginError.coreAudioStatus(-1) = underlying else {
                return XCTFail("expected injected CoreAudio failure, got \(underlying)")
            }
        }
        XCTAssertEqual(controller.previousDefaultOutputUID, uid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: defaultOutputBackupURL.path))
    }

    func testDisableSurfacesSetterFailureAndRetainsRecoveryState() throws {
        let uid = "ExternalUSBDevice"
        try EqualizerHALPluginController.writeDefaultOutputBackup(
            uid: uid,
            to: defaultOutputBackupURL
        )

        let forwardingURL = EqualizerHALPluginController.forwardingTargetURL
        let originalForwardingTarget = try? String(contentsOf: forwardingURL, encoding: .utf8)
        defer {
            if let originalForwardingTarget {
                try? originalForwardingTarget.write(to: forwardingURL, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: forwardingURL)
            }
        }
        EqualizerHALPluginController.writeForwardingTarget(uid: "TargetDevice")

        var shouldFail = true
        var restoredIDs: [AudioObjectID] = []
        let controller = EqualizerHALPluginController(
            defaultOutputBackupURL: defaultOutputBackupURL,
            outputDeviceIDForUID: { $0 == uid ? AudioObjectID(91) : nil },
            defaultOutputSetter: { deviceID in
                if shouldFail {
                    shouldFail = false
                    throw EqualizerHALPluginError.coreAudioStatus(-1)
                }
                restoredIDs.append(deviceID)
            }
        )

        XCTAssertThrowsError(try controller.disable()) { error in
            guard case EqualizerHALPluginError.previousOutputRestoreFailed(underlying: let underlying) = error else {
                return XCTFail("expected previousOutputRestoreFailed, got \(error)")
            }
            guard case EqualizerHALPluginError.coreAudioStatus(-1) = underlying else {
                return XCTFail("expected injected CoreAudio failure, got \(underlying)")
            }
        }
        XCTAssertEqual(controller.previousDefaultOutputUID, uid)
        XCTAssertEqual(controller.previousDefaultOutputID, AudioObjectID(91))
        XCTAssertTrue(FileManager.default.fileExists(atPath: defaultOutputBackupURL.path))
        XCTAssertEqual(controller.currentForwardingTargetUID(), "TargetDevice")

        try controller.disable()
        XCTAssertEqual(restoredIDs, [AudioObjectID(91)])
        XCTAssertNil(controller.previousDefaultOutputUID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultOutputBackupURL.path))
    }

    // MARK: - Default-output observation

    func testDefaultOutputProviderReportsDeviceAndDispatchesOutputChanges() {
        let callbackQueue = DispatchQueue(label: "spotiglass-eq-default-output-test")
        let provider = MacDefaultAudioOutputNameProvider(callbackQueue: callbackQueue)
        let change = expectation(description: "default output change")
        defer { provider.stopListening() }

        provider.startListening {
            change.fulfill()
        }

        XCTAssertNotNil(provider.listenerBlock)
        XCTAssertEqual(
            provider.currentOutputDeviceID,
            MacAudioOutputHardware.defaultOutputDeviceID()
        )

        guard let listener = provider.listenerBlock else {
            return XCTFail("the provider should retain its Core Audio listener")
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        withUnsafePointer(to: &address) { addressPointer in
            listener(1, addressPointer)
        }

        wait(for: [change], timeout: 1)
        provider.stopListening()
        XCTAssertNil(provider.listenerBlock)
    }

    // MARK: - Router readiness and system-output reconciliation

    func testRouterStatusParserReadsReadyAndFailureRecords() throws {
        let statusURL = makeTempDirectory().appendingPathComponent("router.status")
        try "ready\nAirPodsMaxUID\n".write(to: statusURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            EqualizerHALPluginController.readRouterStatus(from: statusURL),
            .ready(targetUID: "AirPodsMaxUID")
        )

        try "failed\nDisconnectedUSBDevice\n3\n".write(
            to: statusURL,
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(
            EqualizerHALPluginController.readRouterStatus(from: statusURL),
            .failed(targetUID: "DisconnectedUSBDevice", reasonCode: 3)
        )
    }

    func testRouterReadinessFailureIsSurfacedWithTheLocalizedEQError() {
        let uid = "DisconnectedUSBDevice"
        let controller = EqualizerHALPluginController(
            routerStatusURL: makeTempDirectory().appendingPathComponent("router.status"),
            routerStatusReader: {
                .failed(targetUID: uid, reasonCode: 3)
            },
            routerReadinessTimeout: 0
        )

        XCTAssertThrowsError(try controller.waitForRouterReadiness(targetUID: uid)) { error in
            guard case let EqualizerHALPluginError.routerTargetOpenFailed(
                targetUID: foundUID,
                reasonCode
            ) = error else {
                return XCTFail("expected routerTargetOpenFailed, got \(error)")
            }
            XCTAssertEqual(foundUID, uid)
            XCTAssertEqual(reasonCode, 3)
            XCTAssertEqual(
                error.localizedDescription,
                SpotiglassL10n.string("eq.error.routerTargetOpenFailed")
            )
        }
    }

    @MainActor
    func testStartDoesNotReportLiveWhenRouterOpenFails() throws {
        let originalID = AudioObjectID(41)
        let virtualID = AudioObjectID(99)
        let uid = "OriginalOutputUID"
        var setIDs: [AudioObjectID] = []
        let controller = EqualizerHALPluginController(
            halDirectory: halDirectory,
            bundle: fakeAppBundle,
            defaultOutputBackupURL: defaultOutputBackupURL,
            outputDeviceUID: { $0 == originalID ? uid : nil },
            defaultOutputDeviceIDProvider: { originalID },
            virtualDeviceIDProvider: { virtualID },
            defaultOutputSetter: { setIDs.append($0) },
            routerStatusURL: makeTempDirectory().appendingPathComponent("router.status"),
            routerStatusReader: {
                .failed(targetUID: uid, reasonCode: 2)
            },
            routerReadinessTimeout: 0,
            activeSampleRateObservationStarter: { _ in }
        )
        try controller.install()
        let engine = AudioEqualizerEngine(pluginController: controller)

        XCTAssertThrowsError(try engine.start()) { error in
            XCTAssertEqual(
                error.localizedDescription,
                SpotiglassL10n.string("eq.error.routerTargetOpenFailed")
            )
        }
        XCTAssertEqual(setIDs, [virtualID])
        XCTAssertFalse(engine.isRunning)
        guard case .failed = engine.routeState else {
            return XCTFail("a failed router must not publish Live state")
        }
    }

    @MainActor
    func testSelectingHardwareOutputWhileEQIsEnabledKeepsVirtualOutputAsDefault() async throws {
        let originalID = AudioObjectID(41)
        let selectedID = AudioObjectID(42)
        let virtualID = AudioObjectID(99)
        let originalUID = "OriginalOutputUID"
        let selectedUID = "SelectedOutputUID"
        var statusTarget = originalUID
        var setIDs: [AudioObjectID] = []
        let controller = EqualizerHALPluginController(
            halDirectory: halDirectory,
            bundle: fakeAppBundle,
            defaultOutputBackupURL: defaultOutputBackupURL,
            outputDeviceUID: { deviceID in
                switch deviceID {
                case originalID: originalUID
                case selectedID: selectedUID
                default: nil
                }
            },
            defaultOutputDeviceIDProvider: { originalID },
            virtualDeviceIDProvider: { virtualID },
            defaultOutputSetter: { setIDs.append($0) },
            routerStatusURL: makeTempDirectory().appendingPathComponent("router.status"),
            routerStatusReader: {
                .ready(targetUID: statusTarget)
            },
            activeSampleRateObservationStarter: { _ in }
        )
        try controller.install()
        let engine = AudioEqualizerEngine(pluginController: controller)
        try engine.start()

        let macOutput = TestEqualizerMacOutputProvider(deviceID: selectedID)
        let viewModel = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander(),
            macAudioOutput: macOutput,
            equalizerEngine: engine,
            defaults: UserDefaults(suiteName: "spotiglass-eq-routing-\(UUID().uuidString)")!
        )
        statusTarget = selectedUID
        viewModel.setSystemDefaultOutputDevice(selectedID)

        XCTAssertEqual(setIDs, [virtualID, virtualID])
        XCTAssertEqual(controller.currentForwardingTargetUID(), selectedUID)
        XCTAssertEqual(
            engine.routeState,
            .live(targetUID: selectedUID, errorMessage: nil)
        )

        // A later Control Center-style notification follows the same route
        // state machine rather than bypassing the EQ or creating a second
        // status interpretation in the playback model.
        statusTarget = originalUID
        macOutput.currentOutputDeviceID = originalID
        macOutput.emitOutputChange()
        for _ in 0..<3 { await Task.yield() }

        XCTAssertEqual(setIDs, [virtualID, virtualID, virtualID])
        XCTAssertEqual(controller.currentForwardingTargetUID(), originalUID)
        XCTAssertEqual(
            engine.routeState,
            .live(targetUID: originalUID, errorMessage: nil)
        )
        XCTAssertTrue(engine.isRunning)
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

    func testForwardingFormatAcceptsOnlyFloat32StereoLayouts() {
        var interleaved = AudioStreamBasicDescription()
        interleaved.mFormatID = kAudioFormatLinearPCM
        interleaved.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        interleaved.mBytesPerPacket = 8
        interleaved.mFramesPerPacket = 1
        interleaved.mBytesPerFrame = 8
        interleaved.mChannelsPerFrame = 2
        interleaved.mBitsPerChannel = 32

        var nonInterleaved = interleaved
        nonInterleaved.mFormatFlags |= kAudioFormatFlagIsNonInterleaved
        nonInterleaved.mBytesPerPacket = 4
        nonInterleaved.mBytesPerFrame = 4

        var integerStereo = interleaved
        integerStereo.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked

        var threeChannel = interleaved
        threeChannel.mChannelsPerFrame = 3
        threeChannel.mBytesPerPacket = 12
        threeChannel.mBytesPerFrame = 12

        XCTAssertTrue(AudioDeviceEnumerator.supportsEQForwarding(format: interleaved))
        XCTAssertTrue(AudioDeviceEnumerator.supportsEQForwarding(format: nonInterleaved))
        XCTAssertFalse(AudioDeviceEnumerator.supportsEQForwarding(format: integerStereo))
        XCTAssertFalse(AudioDeviceEnumerator.supportsEQForwarding(format: threeChannel))
    }

    func testControllerPublishesAChangedDeviceSampleRateOnce() {
        let controller = EqualizerHALPluginController()
        var received: [UInt32] = []
        controller.activeSampleRateDidChange = { received.append($0) }

        XCTAssertTrue(controller.updateActiveSampleRate(nominalRate: 44_100))
        XCTAssertFalse(controller.updateActiveSampleRate(nominalRate: 44_100))
        XCTAssertFalse(controller.updateActiveSampleRate(nominalRate: 0))
        XCTAssertEqual(received, [44_100])
        XCTAssertEqual(controller.activeSampleRate, 44_100)
    }

    @MainActor
    func testActiveSampleRateChangePublishesCoefficientsForThatRate() throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("spotiglass-eq-rate-\(UUID().uuidString).shm")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let publisher = EQCoefficientPublisher(shmPath: path)
        let sampleRateProvider = TestSampleRateProvider(sampleRate: 48_000)
        let engine = AudioEqualizerEngine(
            coefficientPublisher: publisher,
            sampleRateProvider: sampleRateProvider
        )
        var settings = EqualizerSettings(enabled: true)
        settings.bands[5] = 6

        engine.apply(settings: settings)
        let at48k = try XCTUnwrap(publisher.readForTesting())
        sampleRateProvider.setActiveSampleRate(44_100)
        let at44k = try XCTUnwrap(publisher.readForTesting())

        let expectedAt44k = EQCoefficientFrame.build(
            settings: settings,
            sampleRateHz: 44_100
        )
        XCTAssertEqual(at44k.sampleRateHz, 44_100)
        XCTAssertEqual(at44k.bands, expectedAt44k.bands)
        XCTAssertNotEqual(at44k.bands, at48k.bands)
    }

    // MARK: - Helpers

    private func makeTempDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("spotiglass-eq-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class TestEqualizerMacOutputProvider: MacDefaultAudioOutputProviding {
    let currentOutputDisplayName = "Test output"
    var currentOutputDeviceID: AudioDeviceID?
    private var onChange: (() -> Void)?

    init(deviceID: AudioDeviceID) {
        currentOutputDeviceID = deviceID
    }

    func startListening(_ onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func stopListening() {
        onChange = nil
    }

    func emitOutputChange() {
        onChange?()
    }
}
