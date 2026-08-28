import SwiftUI
import ViewInspector
import XCTest

@testable import Spotiglass

/// Rules the Equalizer pane's rows depend on, asserted directly so they do not
/// need a hosted view or a real audio device to be checked.
@MainActor
final class EqualizerSettingsRowTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

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

    func testBandFaderKeyboardArrowsUseTheSharedHalfDecibelStep() throws {
        XCTAssertEqual(
            EqualizerSettingsView.bandGainKeyboardKeys,
            Set([KeyEquivalent.upArrow, .downArrow, .leftArrow, .rightArrow])
        )

        XCTAssertEqual(
            try XCTUnwrap(EqualizerSettingsView.bandGainKeyboardAdjustment(value: 0, key: .upArrow)),
            EqualizerSettingsView.bandGainStep
        )
        XCTAssertEqual(
            try XCTUnwrap(EqualizerSettingsView.bandGainKeyboardAdjustment(value: 0, key: .rightArrow)),
            EqualizerSettingsView.bandGainStep
        )
        XCTAssertEqual(
            try XCTUnwrap(EqualizerSettingsView.bandGainKeyboardAdjustment(value: 0, key: .downArrow)),
            -EqualizerSettingsView.bandGainStep
        )
        XCTAssertEqual(
            try XCTUnwrap(EqualizerSettingsView.bandGainKeyboardAdjustment(value: 0, key: .leftArrow)),
            -EqualizerSettingsView.bandGainStep
        )

        XCTAssertNil(
            EqualizerSettingsView.bandGainKeyboardAdjustment(value: 0, key: .return),
            "non-arrow keys must remain available to their owning controls"
        )
        XCTAssertNil(
            EqualizerSettingsView.bandGainKeyboardAdjustment(value: 0, key: .rightArrow, modifiers: .command),
            "application shortcuts using command arrows must not be swallowed by a fader"
        )
    }

    func testBandFaderKeyboardAdjustmentClampsToTheGainRange() throws {
        let upper = EqualizerSettings.gainRangeDB.upperBound
        let lower = EqualizerSettings.gainRangeDB.lowerBound

        XCTAssertEqual(
            try XCTUnwrap(
                EqualizerSettingsView.bandGainKeyboardAdjustment(
                    value: upper,
                    key: .upArrow
                )),
            upper
        )
        XCTAssertEqual(
            try XCTUnwrap(
                EqualizerSettingsView.bandGainKeyboardAdjustment(
                    value: lower,
                    key: .downArrow
                )),
            lower
        )
    }

    func testBandFaderKeepsDragAndVoiceOverPathsAlongsideKeyboardFocus() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL =
            testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Spotiglass/Settings/EqualizerSettingsView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let faderStart = try XCTUnwrap(source.range(of: "private struct CenterOriginGainFader"))
        let faderSource = source[faderStart.lowerBound...]

        XCTAssertTrue(faderSource.contains(".focusable()"))
        XCTAssertTrue(faderSource.contains(".onKeyPress(keys: EqualizerSettingsView.bandGainKeyboardKeys)"))
        XCTAssertTrue(faderSource.contains("DragGesture(minimumDistance: 0)"))
        XCTAssertTrue(faderSource.contains(".accessibilityAdjustableAction"))
    }

    @MainActor
    func testEqualizerEditorControlsFollowMasterSwitch() throws {
        let disabledStore = try ViewTestHost.makeSettingsStore()
        try disabledStore.mutate { $0.equalizer.enabled = false }
        let disabledView = EqualizerSettingsView(
            settingsStore: disabledStore,
            engine: AudioEqualizerEngine()
        )
        ViewTestHost.host(disabledView, size: CGSize(width: 980, height: 641))
        let disabledForm = try disabledView.inspect().find(ViewType.Form.self)

        // Output routing is intentionally independent of the editor switch.
        let disabledPresetSection = try disabledForm.section(1)
        let disabledOutputPicker = try disabledPresetSection.find(ViewType.Picker.self)
        XCTAssertFalse(disabledOutputPicker.isDisabled())
        let disabledPresetRow = try disabledPresetSection.find(ViewType.LabeledContent.self)
        XCTAssertTrue(disabledPresetRow.isDisabled())
        XCTAssertTrue(try disabledPresetRow.find(ViewType.Picker.self).isDisabled())
        XCTAssertTrue(
            try disabledPresetRow
                .find(button: SpotiglassL10n.string("settings.eq.preset.save"))
                .isDisabled()
        )
        XCTAssertTrue(try disabledForm.section(2).find(ViewType.Slider.self).isDisabled())
        XCTAssertTrue(try disabledForm.section(3).isDisabled())
        XCTAssertTrue(try disabledForm.section(4).isDisabled())
        XCTAssertNoThrow(
            try disabledView.inspect().find(
                text: SpotiglassL10n.string("settings.eq.description.disabled")
            )
        )

        let enabledStore = try ViewTestHost.makeSettingsStore()
        try enabledStore.mutate { $0.equalizer.enabled = true }
        let enabledView = EqualizerSettingsView(
            settingsStore: enabledStore,
            engine: AudioEqualizerEngine()
        )
        ViewTestHost.host(enabledView, size: CGSize(width: 980, height: 641))
        let enabledForm = try enabledView.inspect().find(ViewType.Form.self)
        let enabledPresetSection = try enabledForm.section(1)
        XCTAssertFalse(try enabledPresetSection.find(ViewType.Picker.self).isDisabled())
        let enabledPresetRow = try enabledPresetSection.find(ViewType.LabeledContent.self)
        XCTAssertFalse(enabledPresetRow.isDisabled())
        XCTAssertFalse(
            try enabledPresetRow
                .find(button: SpotiglassL10n.string("settings.eq.preset.save"))
                .isDisabled()
        )
        XCTAssertFalse(try enabledForm.section(2).find(ViewType.Slider.self).isDisabled())
        XCTAssertFalse(try enabledForm.section(3).isDisabled())
        XCTAssertFalse(try enabledForm.section(4).isDisabled())
    }
}
