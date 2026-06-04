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

    func testRendersAppearanceHeaderAndSections() throws {
        let store = try ViewTestHost.makeSettingsStore()
        let view = AppearanceSettingsView(settingsStore: store)
        ViewTestHost.host(view)
        // The pane no longer repeats its title (the window header shows it, #26),
        // so the header now renders only the subtitle.
        ViewTestHost.assertFindLocalizedText("settings.section.appearance.subtitle", in: view)
        ViewTestHost.assertFindLocalizedText("settings.appearance.colorScheme", in: view)
        ViewTestHost.assertFindLocalizedText("settings.appearance.commandPalette", in: view)
    }
}
