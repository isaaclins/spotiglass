import AppKit
import SwiftUI
import XCTest
@testable import Spotiglass

/// Switching the language in an open Settings window left the segmented controls in
/// the old language: headings and hints changed, but the color-scheme and lyrics-size
/// choices still read "Hell / Dunkel" and "Klein / Mittel / Gross" (#460). SwiftUI
/// updated its own text, while the AppKit segmented control kept the labels it was
/// built with. These tests read the labels off the real controls, not the SwiftUI tree.
@MainActor
final class SettingsLanguageSwitchTests: XCTestCase {
    override func tearDown() {
        SpotiglassL10n.settingsStore = nil
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    func testAppearanceOptionLabelsFollowEveryLanguageSwitch() throws {
        let store = try ViewTestHost.makeSettingsStore()
        SpotiglassL10n.settingsStore = store
        try store.mutate { $0.appearance.language = .german }

        let controller = hostAppearance(store)

        assertSegmentLabels(in: controller.view, for: .german)
        for language in [AppLanguage.english, .spanish, .german, .english] {
            try store.mutate { $0.appearance.language = language }
            controller.view.layoutSubtreeIfNeeded()
            AppKitTestSupport.pumpRunLoop()
            assertSegmentLabels(in: controller.view, for: language)
        }
    }

    /// Keyboard users change the language with the arrow keys on the language picker.
    /// Rebuilding the whole pane on a switch took focus off that picker, so the next
    /// arrow key went nowhere. Only the pickers with translated options are rebuilt.
    func testLanguagePickerKeepsKeyboardFocusAcrossASwitch() throws {
        let store = try ViewTestHost.makeSettingsStore()
        SpotiglassL10n.settingsStore = store
        try store.mutate { $0.appearance.language = .german }

        let controller = hostAppearance(store)
        let window = try XCTUnwrap(controller.view.window)
        let picker = try XCTUnwrap(languagePicker(in: controller.view))
        XCTAssertTrue(AppKitTestSupport.makeFirstResponder(picker, in: window))

        try store.mutate { $0.appearance.language = .english }
        controller.view.layoutSubtreeIfNeeded()
        AppKitTestSupport.pumpRunLoop()

        let pickerAfter = try XCTUnwrap(languagePicker(in: controller.view))
        XCTAssertTrue(pickerAfter === picker, "The language picker was rebuilt by the switch")
        XCTAssertTrue(window.firstResponder === picker, "The switch took keyboard focus off the language picker")
        // The other pickers still follow the switch.
        assertSegmentLabels(in: controller.view, for: .english)
    }

    // MARK: - Helpers

    private func hostAppearance(_ store: SpotiglassSettingsStore) -> NSHostingController<AnyView> {
        ViewTestHost.host(
            AppearanceSettingsView(settingsStore: store)
                .environment(\.spotiglassLocale, store.appLocale),
            size: CGSize(width: 640, height: 900)
        )
    }

    private func languagePicker(in view: NSView) -> NSSegmentedControl? {
        let names = AppLanguage.allCases.map(\.nativeDisplayName)
        return segmentedControls(in: view).first { control in
            (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "" } == names
        }
    }

    private func assertSegmentLabels(
        in view: NSView,
        for language: AppLanguage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let locale = Locale(identifier: language.rawValue)
        let expected = [
            AppearanceColorScheme.allCases.map {
                SpotiglassL10n.string("settings.appearance.scheme.\($0.rawValue)", locale: locale)
            },
            LyricsTextSize.allCases.map {
                SpotiglassL10n.string("settings.appearance.lyricsSize.\($0.rawValue)", locale: locale)
            },
        ]
        let shown = segmentedControls(in: view).map { control in
            (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "" }
        }
        for labels in expected {
            XCTAssertTrue(
                shown.contains(labels),
                "Expected segments \(labels) in \(language), found \(shown)",
                file: file,
                line: line
            )
        }
    }

    private func segmentedControls(in view: NSView) -> [NSSegmentedControl] {
        ((view as? NSSegmentedControl).map { [$0] } ?? []) + view.subviews.flatMap { segmentedControls(in: $0) }
    }

}
