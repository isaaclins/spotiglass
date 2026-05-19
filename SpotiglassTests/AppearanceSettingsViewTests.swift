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

        let inspected = try view.inspect()
        XCTAssertNoThrow(try inspected.find(text: "Appearance"))
        XCTAssertNoThrow(try inspected.find(text: "Color scheme"))
        XCTAssertNoThrow(try inspected.find(text: "Command palette"))
    }
}
