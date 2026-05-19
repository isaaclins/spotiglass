import AppKit
import Carbon
import SwiftUI
import XCTest
@testable import Spotiglass

/// US QWERTY virtual key codes so key events are layout-independent in tests.
private enum USKeyboard {
    static func virtualKey(for key: String) -> CGKeyCode? {
        guard key.count == 1, let scalar = key.unicodeScalars.first else { return nil }
        if scalar.value >= 97, scalar.value <= 122 {
            let codes: [CGKeyCode] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6, 18, 19, 20, 21, 23]
            return codes[Int(scalar.value - 97)]
        }
        if scalar.value >= 48, scalar.value <= 57 {
            return CGKeyCode(scalar.value - 48 + 29)
        }
        return nil
    }
}

@MainActor
/// `Z` prefix keeps this suite last; AppKit recording tests destabilize the next suite if they run immediately before it.
final class ZHotkeyRecorderFieldTests: XCTestCase {
    private static let suiteLock = NSLock()
    private var windows: [NSWindow] = []
    /// Keeps coordinators alive; `RecorderKeyContainerView` holds them only weakly.
    private var harnessRoots: [AnyObject] = []

    override func setUp() {
        Self.suiteLock.lock()
        super.setUp()
        AppKitTestSupport.activateAppIfNeeded()
        AppKitTestSupport.pumpRunLoop(for: 0.03)
    }

    override func tearDown() {
        harnessRoots.compactMap { $0 as? RecorderKeyContainerView }.forEach { view in
            if view.isRecording {
                view.cancelRecording()
            }
        }
        harnessRoots.compactMap { $0 as? HotkeyRecorderField.Coordinator }.forEach { $0.teardownMonitors() }
        windows.forEach { window in
            window.makeFirstResponder(nil)
            window.close()
        }
        windows.removeAll()
        harnessRoots.removeAll()
        ViewTestHost.tearDownAll()
        AppKitTestSupport.pumpRunLoop(for: 0.05)
        super.tearDown()
        Self.suiteLock.unlock()
    }

    private func makeHarness(
        commandID: String = CommandPaletteCommandID.openSettings,
        onRecordingChange: @escaping (Bool) -> Void = { _ in },
        onCaptureConflict: @escaping (CommandShortcut, String) -> Void = { _, _ in },
        onApplied: @escaping () -> Void = {}
    ) throws -> (
        HotkeyRecorderField,
        CommandPaletteKeymapStore,
        RecorderKeyContainerView,
        HotkeyRecorderField.Coordinator,
        NSWindow
    ) {
        let url = makeCommandPaletteTestsTempSettingsURL()
        let settings = SpotiglassSettingsStore(fileURL: url)
        let keymap = CommandPaletteKeymapStore(settingsStore: settings)
        let field = HotkeyRecorderField(
            commandID: commandID,
            keymapStore: keymap,
            onRecordingChange: onRecordingChange,
            onCaptureConflict: onCaptureConflict,
            onApplied: onApplied
        )
        let coordinator = HotkeyRecorderField.Coordinator(field)
        let view = RecorderKeyContainerView(frame: NSRect(x: 0, y: 0, width: 220, height: 32))
        view.coordinator = coordinator
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 40),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
        harnessRoots.append(settings)
        harnessRoots.append(keymap)
        harnessRoots.append(coordinator)
        harnessRoots.append(view)
        return (field, keymap, view, coordinator, window)
    }

    private func beginRecording(on view: RecorderKeyContainerView, in window: NSWindow) -> Bool {
        view.coordinator?.teardownMonitors()
        window.makeKeyAndOrderFront(nil)
        guard window.makeFirstResponder(view) else { return false }
        AppKitTestSupport.pumpRunLoop(for: 0.02)
        return view.isRecording
    }

    private func keyEvent(
        virtualKey: CGKeyCode,
        modifierFlags: NSEvent.ModifierFlags = [],
        window: NSWindow
    ) -> NSEvent {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cgEvent = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)!
        var flags = CGEventFlags()
        if modifierFlags.contains(.command) { flags.insert(.maskCommand) }
        if modifierFlags.contains(.shift) { flags.insert(.maskShift) }
        if modifierFlags.contains(.control) { flags.insert(.maskControl) }
        if modifierFlags.contains(.option) { flags.insert(.maskAlternate) }
        cgEvent.flags = flags
        return NSEvent(cgEvent: cgEvent)!
    }

    private func keyEvent(
        for shortcut: CommandShortcut,
        window: NSWindow
    ) throws -> NSEvent {
        guard let virtualKey = USKeyboard.virtualKey(for: shortcut.key) else {
            throw XCTSkip("No US virtual key mapping for \(shortcut.key)")
        }
        return keyEvent(virtualKey: virtualKey, modifierFlags: shortcut.modifiers, window: window)
    }

    /// One window session avoids repeated first-responder / NSEvent-monitor cycles that time out under XCTest.
    func testRecordingCaptureConflictApplyDeleteAndEscape() throws {
        var recording = false
        var applied = 0
        var conflict: (CommandShortcut, String)?
        let stolen = try CommandShortcut(keystroke: "ctrl-j")
        let (field, keymap, view, _, window) = try makeHarness(
            onRecordingChange: { recording = $0 },
            onCaptureConflict: { shortcut, otherID in conflict = (shortcut, otherID) },
            onApplied: { applied += 1 }
        )
        try keymap.setBinding(
            commandID: CommandPaletteCommandID.openPalette,
            shortcut: stolen,
            replaceConflicting: true
        )

        XCTAssertTrue(beginRecording(on: view, in: window))
        view.updateLiveModifierChips([.command, .shift])
        XCTAssertTrue(view.subviews.first(where: { $0 is NSButton }) is NSButton)

        view.keyDown(with: try keyEvent(for: stolen, window: window))
        XCTAssertEqual(conflict?.0, stolen)
        XCTAssertEqual(conflict?.1, CommandPaletteCommandID.openPalette)
        XCTAssertFalse(view.isRecording)

        XCTAssertTrue(beginRecording(on: view, in: window))
        view.keyDown(with: keyEvent(virtualKey: 25, modifierFlags: [.control], window: window))
        XCTAssertEqual(applied, 1)
        XCTAssertNotNil(keymap.primaryShortcut(for: field.commandID))

        let bound = try XCTUnwrap(keymap.primaryShortcut(for: field.commandID))
        try keymap.setBinding(commandID: field.commandID, shortcut: bound, replaceConflicting: true)
        view.syncFromStore()
        XCTAssertTrue(beginRecording(on: view, in: window))
        view.keyDown(with: keyEvent(virtualKey: 51, window: window))
        XCTAssertEqual(applied, 2)
        XCTAssertNil(keymap.primaryShortcut(for: field.commandID))

        XCTAssertTrue(beginRecording(on: view, in: window))
        XCTAssertTrue(recording)
        view.keyDown(with: keyEvent(virtualKey: 53, window: window))
        XCTAssertFalse(view.isRecording)
        XCTAssertFalse(recording)

        view.coordinator?.teardownMonitors()
        view.coordinator?.teardownMonitors()
    }

    func testSwiftUIRepresentableMounts() throws {
        let url = makeCommandPaletteTestsTempSettingsURL()
        let settings = SpotiglassSettingsStore(fileURL: url)
        let keymap = CommandPaletteKeymapStore(settingsStore: settings)
        harnessRoots.append(settings)
        harnessRoots.append(keymap)
        let spec = CommandPaletteCommandCatalog.editable.first!
        let field = HotkeyRecorderField(
            commandID: spec.commandID,
            keymapStore: keymap,
            onRecordingChange: { _ in },
            onCaptureConflict: { _, _ in },
            onApplied: {}
        )
        let controller = NSHostingController(rootView: field.frame(width: 200, height: 28))
        harnessRoots.append(controller)
        controller.view.frame = NSRect(x: 0, y: 0, width: 200, height: 28)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(controller.view.bounds.width, 100)
        XCTAssertEqual(field.commandID, spec.commandID)
    }
}
