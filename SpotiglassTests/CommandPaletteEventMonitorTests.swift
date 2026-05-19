import SwiftUI
import ViewInspector
import XCTest
@testable import Spotiglass

@MainActor
final class CommandPaletteEventMonitorTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    func testEventMonitorHostsAndDismantles() throws {
        let manager = CommandPaletteManager()
        let wrapper = CommandPaletteEventMonitor(manager: manager)
            .frame(width: 1, height: 1)
        ViewTestHost.host(wrapper, size: CGSize(width: 4, height: 4))
        XCTAssertNoThrow(try wrapper.inspect())
    }

    func testCoordinatorForwardsKeyEventsToManager() {
        let manager = CommandPaletteManager()
        let coordinator = CommandPaletteEventMonitor.Coordinator(manager: manager)
        coordinator.start()
        manager.viewModel.show()
        let escape = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 53
        )!
        let handled = MainActor.assumeIsolated {
            manager.handleKeyEvent(escape)
        }
        XCTAssertTrue(handled)
        XCTAssertFalse(manager.viewModel.isPresented)
        coordinator.stop()
    }
}
