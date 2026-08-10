import XCTest

@testable import Spotiglass

/// Round-trip + precedence coverage for the forwarding-target UID that
/// `EqualizerHALPluginController` persists across enable→disable cycles.
/// The static decision rule and the /tmp file I/O are tested directly so
/// the test process doesn't need a loaded `Spotiglass EQ` HAL device.
final class EqualizerForwardingTargetTests: XCTestCase {
    override func setUp() {
        super.setUp()
        EqualizerHALPluginController.clearForwardingTarget()
    }

    override func tearDown() {
        EqualizerHALPluginController.clearForwardingTarget()
        super.tearDown()
    }

    // MARK: - Precedence

    func testResolvePrefersExplicitlyPersistedPick() {
        let resolved = EqualizerHALPluginController.resolveForwardingTargetUID(
            preferred: "AirPodsMaxUID",
            previousUID: "BuiltInSpeakerDevice"
        )
        XCTAssertEqual(resolved, "AirPodsMaxUID")
    }

    func testResolveFallsBackToPreviousDefaultWhenNoPick() {
        let resolved = EqualizerHALPluginController.resolveForwardingTargetUID(
            preferred: nil,
            previousUID: "ExternalUSBDevice"
        )
        XCTAssertEqual(resolved, "ExternalUSBDevice")
    }

    func testResolveTreatsEmptyPreferredAsNoPick() {
        let resolved = EqualizerHALPluginController.resolveForwardingTargetUID(
            preferred: "",
            previousUID: "ExternalUSBDevice"
        )
        XCTAssertEqual(resolved, "ExternalUSBDevice")
    }

    func testResolveFallsBackToBuiltInSpeakerWhenNeitherSet() {
        let resolved = EqualizerHALPluginController.resolveForwardingTargetUID(
            preferred: nil,
            previousUID: nil
        )
        XCTAssertEqual(resolved, EqualizerHALPluginController.fallbackForwardingUID)
    }

    // MARK: - File round-trip

    func testWritingTargetUIDPersistsItToDisk() {
        EqualizerHALPluginController.writeForwardingTarget(uid: "AirPodsMaxUID")
        let controller = EqualizerHALPluginController()
        XCTAssertEqual(controller.currentForwardingTargetUID(), "AirPodsMaxUID")
    }

    func testClearForwardingTargetRemovesIt() {
        EqualizerHALPluginController.writeForwardingTarget(uid: "AirPodsMaxUID")
        EqualizerHALPluginController.clearForwardingTarget()
        let controller = EqualizerHALPluginController()
        XCTAssertNil(controller.currentForwardingTargetUID())
    }

    func testDisableEnableRoundTripPreservesSavedPick() {
        // Simulates the lifecycle: user picks UID → disable() clears the
        // file → re-enable() with the persisted UID rewrites it. We exercise
        // the steps directly (no real device required) to confirm the saved
        // pick is what ends up on disk.
        let savedUID = "AirPodsMaxUID"
        EqualizerHALPluginController.writeForwardingTarget(uid: savedUID)
        EqualizerHALPluginController.clearForwardingTarget()
        let recomputed = EqualizerHALPluginController.resolveForwardingTargetUID(
            preferred: savedUID,
            previousUID: nil
        )
        EqualizerHALPluginController.writeForwardingTarget(uid: recomputed)
        let controller = EqualizerHALPluginController()
        XCTAssertEqual(controller.currentForwardingTargetUID(), savedUID)
    }
}
