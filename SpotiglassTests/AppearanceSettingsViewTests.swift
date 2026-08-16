import SwiftUI
import ViewInspector
import XCTest
@testable import Spotiglass

@MainActor
final class AppearanceSettingsViewTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    func testRendersAppearanceSectionsInAGroupedForm() throws {
        let store = try ViewTestHost.makeSettingsStore()
        let view = AppearanceSettingsView(settingsStore: store)
        ViewTestHost.host(view)
        // The pane carries neither a title nor a subtitle. The window header names
        // the pane (#26), and a subtitle restating that rendered between the first
        // two groups, where it read as a footnote to Language rather than as a
        // description of the pane. Each group now explains only itself.
        XCTAssertNoThrow(try view.inspect().find(ViewType.Form.self))
        ViewTestHost.assertFindLocalizedText("settings.appearance.language", in: view)
        ViewTestHost.assertFindLocalizedText("settings.appearance.colorScheme", in: view)
        ViewTestHost.assertFindLocalizedText("settings.appearance.commandPalette", in: view)
    }

    /// One heading owned two controls that never agreed, so the running build
    /// showed Small selected beside a slider reading 300% (#165). The preset
    /// reported is now the one nearest the size actually in use.
    func testLyricsPresetReflectsTheEffectiveSize() {
        // Small at 300% is 51 points, which is nowhere near Small.
        let stretched = AppearanceSettings(lyricsTextSize: .small, lyricsTextScale: 3.0)
        XCTAssertEqual(stretched.lyricsTextMetrics.activeFontSize, 17 * 3.0, accuracy: 0.001)
        XCTAssertEqual(
            LyricsTextSize.nearest(activeFontSize: stretched.lyricsTextMetrics.activeFontSize),
            .large,
            "Small at 300% must not report itself as Small"
        )

        // At scale 1 every preset reports itself.
        for size in LyricsTextSize.allCases {
            let plain = AppearanceSettings(lyricsTextSize: size, lyricsTextScale: 1.0)
            XCTAssertEqual(
                LyricsTextSize.nearest(activeFontSize: plain.lyricsTextMetrics.activeFontSize),
                size
            )
        }

        // Shrinking large reports the smaller preset it now resembles.
        let shrunk = AppearanceSettings(lyricsTextSize: .large, lyricsTextScale: 0.7)
        XCTAssertEqual(
            LyricsTextSize.nearest(activeFontSize: shrunk.lyricsTextMetrics.activeFontSize),
            .medium
        )
    }
}
