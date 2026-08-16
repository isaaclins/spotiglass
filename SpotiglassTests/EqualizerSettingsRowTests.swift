import XCTest
@testable import Spotiglass

/// Rules the Equalizer pane's rows depend on, asserted directly so they do not
/// need a hosted view or a real audio device to be checked.
final class EqualizerSettingsRowTests: XCTestCase {
    /// A saved device that is not connected matches no picker tag, and SwiftUI
    /// then draws the popup with no label at all (#166).
    func testUnavailableSavedForwardingTargetIsReportedOnlyWhenMissing() {
        XCTAssertEqual(
            EqualizerSettingsView.unavailableSavedForwardingUID(
                savedUID: "AirPodsMaxUID",
                deviceUIDs: ["BuiltInSpeakerUID", "DisplayAudioUID"]
            ),
            "AirPodsMaxUID"
        )

        XCTAssertNil(
            EqualizerSettingsView.unavailableSavedForwardingUID(
                savedUID: "BuiltInSpeakerUID",
                deviceUIDs: ["BuiltInSpeakerUID", "DisplayAudioUID"]
            )
        )

        // System default is the absence of a saved device, not a missing one.
        XCTAssertNil(
            EqualizerSettingsView.unavailableSavedForwardingUID(
                savedUID: nil,
                deviceUIDs: ["BuiltInSpeakerUID"]
            )
        )
        XCTAssertNil(
            EqualizerSettingsView.unavailableSavedForwardingUID(
                savedUID: "",
                deviceUIDs: ["BuiltInSpeakerUID"]
            )
        )

        // With nothing connected, the saved device is still the saved device.
        XCTAssertEqual(
            EqualizerSettingsView.unavailableSavedForwardingUID(
                savedUID: "AirPodsMaxUID",
                deviceUIDs: []
            ),
            "AirPodsMaxUID"
        )
    }

    /// All ten faders used to announce the identical "Band gain", so the set
    /// could not be told apart by ear (#115).
    func testEveryBandIsSpokenWithItsOwnFrequencyAndUnit() {
        let bands: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        let spoken = bands.map { EqualizerSettingsView.spokenFrequency(hz: $0) }

        XCTAssertEqual(Set(spoken).count, bands.count)
        XCTAssertEqual(spoken.first, "32 Hz")
        XCTAssertEqual(spoken.last, "16 kHz")
        XCTAssertEqual(EqualizerSettingsView.spokenFrequency(hz: 1000), "1 kHz")
        for label in spoken {
            XCTAssertTrue(label.hasSuffix("Hz"), "\(label) carries no unit")
        }

        let formatted = spoken.map { SpotiglassL10n.format("settings.eq.bandGain.accessibility", $0) }
        XCTAssertEqual(Set(formatted).count, bands.count)
        XCTAssertTrue(formatted[5].contains("1 kHz"), "expected the band in the label, got \(formatted[5])")
    }
}
