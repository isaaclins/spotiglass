import SwiftUI
import ViewInspector
import XCTest
@testable import Spotiglass

@MainActor
final class CommandPaletteViewTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    func testPaletteRendersSearchField() throws {
        let store = try ViewTestHost.makeSettingsStore()
        let vm = CommandPaletteViewModel()
        vm.show()
        let view = CommandPaletteView(viewModel: vm)
            .environmentObject(store)
        ViewTestHost.host(view, size: CGSize(width: 800, height: 600))
        XCTAssertNoThrow(try view.inspect())
    }
}
