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
}
