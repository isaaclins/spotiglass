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
        let host = ViewTestHost.host(
            CommandPaletteEventMonitor(manager: manager).frame(width: 1, height: 1),
            size: CGSize(width: 4, height: 4)
        )
        XCTAssertGreaterThan(host.view.bounds.width, 0)
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

    func testFocusedRecorderReceivesSpaceBeforeGlobalShortcut() throws {
        let settings = SpotiglassSettingsStore(fileURL: makeCommandPaletteTestsTempSettingsURL())
        let keymap = CommandPaletteKeymapStore(settingsStore: settings)
        let manager = CommandPaletteManager(keymapStore: keymap)
        manager.isSignedIn = true

        var playbackToggles = 0
        manager.togglePlayback = { playbackToggles += 1 }

        let field = HotkeyRecorderField(
            commandID: CommandPaletteCommandID.openSettings,
            keymapStore: keymap,
            onRecordingChange: { manager.isRecordingHotkey = $0 },
            onCaptureConflict: { _, _ in },
            onApplied: {}
        )
        let recorderCoordinator = HotkeyRecorderField.Coordinator(field)
        let recorder = RecorderKeyContainerView(
            frame: NSRect(x: 0, y: 0, width: 220, height: 32)
        )
        recorder.coordinator = recorderCoordinator

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 40),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = recorder
        window.isReleasedWhenClosed = false

        let monitor = CommandPaletteEventMonitor.Coordinator(manager: manager)
        defer {
            monitor.stop()
            recorder.cancelRecording()
            AppKitTestSupport.closeWindowSafely(window)
        }

        AppKitTestSupport.activateAppIfNeeded()
        window.makeKeyAndOrderFront(nil)
        AppKitTestSupport.pumpRunLoop()
        XCTAssertTrue(window.makeFirstResponder(recorder))
        XCTAssertTrue(window.firstResponder === recorder)

        monitor.start()
        let space = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: " ",
                charactersIgnoringModifiers: " ",
                isARepeat: false,
                keyCode: 49
            )
        )
        NSApp.sendEvent(space)
        AppKitTestSupport.pumpRunLoop()

        XCTAssertTrue(recorder.isRecording)
        XCTAssertTrue(manager.isRecordingHotkey)
        XCTAssertEqual(playbackToggles, 0)
    }
}
