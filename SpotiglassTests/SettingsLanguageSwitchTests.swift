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

        let controller = ViewTestHost.host(
            SettingsPaneContainer(settingsStore: store) {
                AppearanceSettingsView(settingsStore: store)
            }
            .environment(\.spotiglassLocale, store.appLocale),
            size: CGSize(width: 640, height: 900)
        )

        assertSegmentLabels(in: controller.view, for: .german)
        for language in [AppLanguage.english, .spanish, .german, .english] {
            try store.mutate { $0.appearance.language = language }
            controller.view.layoutSubtreeIfNeeded()
            AppKitTestSupport.pumpRunLoop()
            assertSegmentLabels(in: controller.view, for: language)
        }
    }

    // MARK: - Helpers

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
