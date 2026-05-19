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
final class HotkeyRecorderFieldTests: XCTestCase {
    private var windows: [NSWindow] = []
    /// Keeps coordinators alive; `RecorderKeyContainerView` holds them only weakly.
    private var harnessRoots: [AnyObject] = []

    override func setUp() {
        super.setUp()
        AppKitTestSupport.activateAppIfNeeded()
    }

    override func tearDown() {
        harnessRoots.compactMap { $0 as? HotkeyRecorderField.Coordinator }.forEach { $0.teardownMonitors() }
        windows.forEach { $0.close() }
        windows.removeAll()
        harnessRoots.removeAll()
        ViewTestHost.tearDownAll()
        super.tearDown()
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
        AppKitTestSupport.makeFirstResponder(view, in: window)
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

    func testRecordingShowsModifierChipsAndEndsOnEscape() throws {
        var recording = false
        let (_, _, view, _, window) = try makeHarness(onRecordingChange: { recording = $0 })
        XCTAssertTrue(beginRecording(on: view, in: window))
        XCTAssertTrue(view.isRecording)
        XCTAssertTrue(recording)

        view.updateLiveModifierChips([.command, .shift])
        XCTAssertTrue(view.subviews.first(where: { $0 is NSButton }) is NSButton)

        view.keyDown(with: keyEvent(virtualKey: 53, window: window))
        XCTAssertFalse(view.isRecording)
        XCTAssertFalse(recording)
    }

    func testDeleteClearsBindingAndApplies() throws {
        var applied = 0
        let (field, keymap, view, _, window) = try makeHarness(onApplied: { applied += 1 })
        let shortcut = try CommandShortcut(keystroke: "shift-cmd-0")
        try keymap.setBinding(commandID: field.commandID, shortcut: shortcut, replaceConflicting: true)
        view.syncFromStore()

        XCTAssertTrue(beginRecording(on: view, in: window))
        view.keyDown(with: keyEvent(virtualKey: 51, window: window))
        XCTAssertEqual(applied, 1)
        XCTAssertNil(keymap.primaryShortcut(for: field.commandID))
        XCTAssertFalse(view.isRecording)
    }

    func testCaptureShortcutAppliesBinding() throws {
        var applied = 0
        let (field, keymap, view, _, window) = try makeHarness(onApplied: { applied += 1 })
        XCTAssertTrue(beginRecording(on: view, in: window))

        view.keyDown(with: keyEvent(virtualKey: 25, modifierFlags: [.command], window: window))
        XCTAssertEqual(applied, 1)
        XCTAssertNotNil(keymap.primaryShortcut(for: field.commandID))
    }

    func testCaptureConflictInvokesCallback() throws {
        var conflict: (CommandShortcut, String)?
        let stolen = try CommandShortcut(keystroke: "cmd-k")
        let (field, keymap, view, _, window) = try makeHarness(
            commandID: CommandPaletteCommandID.openSettings,
            onCaptureConflict: { shortcut, otherID in conflict = (shortcut, otherID) }
        )
        try keymap.setBinding(
            commandID: CommandPaletteCommandID.openPalette,
            shortcut: stolen,
            replaceConflicting: true
        )
        XCTAssertTrue(beginRecording(on: view, in: window))

        view.keyDown(with: try keyEvent(for: stolen, window: window))
        XCTAssertEqual(conflict?.0, stolen)
        XCTAssertEqual(conflict?.1, CommandPaletteCommandID.openPalette)
        XCTAssertEqual(keymap.primaryShortcut(for: CommandPaletteCommandID.openPalette), stolen)
        XCTAssertNotEqual(keymap.primaryShortcut(for: field.commandID), stolen)
    }

    func testCoordinatorTeardownAfterRecording() throws {
        var recording = false
        let (_, _, view, coordinator, window) = try makeHarness(onRecordingChange: { recording = $0 })
        XCTAssertTrue(beginRecording(on: view, in: window))
        XCTAssertTrue(recording)
        coordinator.recordingEnded()
        XCTAssertFalse(recording)
        coordinator.teardownMonitors()
        view.cancelRecording()
        XCTAssertFalse(view.isRecording)
    }

    func testSwiftUIHostInspects() throws {
        let (_, keymap, _, _, _) = try makeHarness()
        let spec = CommandPaletteCommandCatalog.editable.first!
        let field = HotkeyRecorderField(
            commandID: spec.commandID,
            keymapStore: keymap,
            onRecordingChange: { _ in },
            onCaptureConflict: { _, _ in },
            onApplied: {}
        )
        ViewTestHost.host(field.frame(width: 200, height: 28))
        XCTAssertNoThrow(try field.inspect())
    }
}
