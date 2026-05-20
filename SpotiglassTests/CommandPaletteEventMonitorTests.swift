import AppKit
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

    func testEventMonitorNSHostingLifecycle() {
        let manager = CommandPaletteManager()
        let host = NSHostingController(
            rootView: CommandPaletteEventMonitor(manager: manager).frame(width: 1, height: 1)
        )
        host.view.frame = NSRect(x: 0, y: 0, width: 4, height: 4)
        host.view.layoutSubtreeIfNeeded()
        host.view.removeFromSuperview()
    }

    func testEventMonitorHostsAndDismantles() throws {
        let manager = CommandPaletteManager()
        let wrapper = CommandPaletteEventMonitor(manager: manager)
            .frame(width: 1, height: 1)
        ViewTestHost.host(wrapper, size: CGSize(width: 4, height: 4))
        XCTAssertNoThrow(try wrapper.inspect())
    }

    func testCoordinatorUpdateAndDismantle() {
        let manager = CommandPaletteManager()
        let monitor = CommandPaletteEventMonitor(manager: manager)
        let coordinator = monitor.makeCoordinator()
        let nsView = NSView(frame: .zero)
        coordinator.start()
        let replacement = CommandPaletteManager()
        coordinator.manager = replacement
        CommandPaletteEventMonitor.dismantleNSView(nsView, coordinator: coordinator)
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

    func testCoordinatorIgnoresUnhandledEvents() {
        let manager = CommandPaletteManager()
        let coordinator = CommandPaletteEventMonitor.Coordinator(manager: manager)
        coordinator.start()
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "x",
            charactersIgnoringModifiers: "x",
            isARepeat: false,
            keyCode: 0
        )!
        let handled = MainActor.assumeIsolated {
            manager.handleKeyEvent(event)
        }
        XCTAssertFalse(handled)
        coordinator.stop()
    }

    func testMakeCoordinatorStartsOnlyOnce() {
        let manager = CommandPaletteManager()
        let monitor = CommandPaletteEventMonitor(manager: manager)
        let coordinator = monitor.makeCoordinator()
        coordinator.start()
        coordinator.start()
        coordinator.stop()
    }
}
