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
        for view in harnessRoots.compactMap({ $0 as? RecorderKeyContainerView }) where view.isRecording {
            view.cancelRecording()
        }
        for coordinator in harnessRoots.compactMap({ $0 as? HotkeyRecorderField.Coordinator }) {
            coordinator.teardownMonitors()
        }
        for window in windows {
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
        onApplied: @escaping () -> Void = {},
        attachWindow: Bool = false
    ) throws -> (
        HotkeyRecorderField,
        CommandPaletteKeymapStore,
        RecorderKeyContainerView,
        HotkeyRecorderField.Coordinator,
        NSWindow?
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
        var window: NSWindow?
        if attachWindow {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 240, height: 40),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            w.contentView = view
            w.makeKeyAndOrderFront(nil)
            windows.append(w)
            window = w
        }
        harnessRoots.append(settings)
        harnessRoots.append(keymap)
        harnessRoots.append(coordinator)
        harnessRoots.append(view)
        return (field, keymap, view, coordinator, window)
    }

    private func keyEvent(
        virtualKey: CGKeyCode,
        modifierFlags: NSEvent.ModifierFlags = []
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

    private func keyEvent(for shortcut: CommandShortcut) throws -> NSEvent {
        guard let virtualKey = USKeyboard.virtualKey(for: shortcut.key) else {
            throw XCTSkip("No US virtual key mapping for \(shortcut.key)")
        }
        return keyEvent(virtualKey: virtualKey, modifierFlags: shortcut.modifiers)
    }

    func testCaptureConflictShortcutEndsRecording() throws {
        var conflict: (CommandShortcut, String)?
        let stolen = try CommandShortcut(keystroke: "ctrl-j")
        let (field, keymap, view, _, _) = try makeHarness(
            onCaptureConflict: { shortcut, otherID in conflict = (shortcut, otherID) }
        )
        try keymap.setBinding(
            commandID: CommandPaletteCommandID.openPalette,
            shortcut: stolen,
            replaceConflicting: true
        )

        view.testing_beginKeyCapture()
        view.updateLiveModifierChips([.command, .shift])
        view.keyDown(with: try keyEvent(for: stolen))

        XCTAssertEqual(conflict?.0, stolen)
        XCTAssertEqual(conflict?.1, CommandPaletteCommandID.openPalette)
        XCTAssertFalse(view.isRecording)
        _ = field
    }

    func testApplyShortcutUpdatesKeymap() throws {
        var applied = 0
        let (_, keymap, view, _, _) = try makeHarness(onApplied: { applied += 1 })

        view.testing_beginKeyCapture()
        view.keyDown(with: keyEvent(virtualKey: 25, modifierFlags: [.control]))

        XCTAssertEqual(applied, 1)
        XCTAssertNotNil(keymap.primaryShortcut(for: CommandPaletteCommandID.openSettings))
        XCTAssertFalse(view.isRecording)
    }

    func testDeleteClearsBinding() throws {
        var applied = 0
        let (field, keymap, view, _, _) = try makeHarness(onApplied: { applied += 1 })
        let bound = try CommandShortcut(keystroke: "ctrl-k")
        try keymap.setBinding(commandID: field.commandID, shortcut: bound, replaceConflicting: true)

        view.testing_beginKeyCapture()
        view.keyDown(with: keyEvent(virtualKey: 51))

        XCTAssertEqual(applied, 1)
        XCTAssertNil(keymap.primaryShortcut(for: field.commandID))
        XCTAssertFalse(view.isRecording)
    }

    func testEscapeCancelsRecording() throws {
        var recording = false
        let (_, _, view, _, _) = try makeHarness(onRecordingChange: { recording = $0 })

        view.testing_beginKeyCapture()
        XCTAssertTrue(recording)
        view.keyDown(with: keyEvent(virtualKey: 53))

        XCTAssertFalse(view.isRecording)
        XCTAssertFalse(recording)
    }

    func testHostedRepresentableUpdateAndTeardown() throws {
        let url = makeCommandPaletteTestsTempSettingsURL()
        let settings = SpotiglassSettingsStore(fileURL: url)
        let keymap = CommandPaletteKeymapStore(settingsStore: settings)
        harnessRoots.append(settings)
        harnessRoots.append(keymap)
        let field = HotkeyRecorderField(
            commandID: CommandPaletteCommandID.openSettings,
            keymapStore: keymap,
            onRecordingChange: { _ in },
            onCaptureConflict: { _, _ in },
            onApplied: {}
        )
        ViewTestHost.host(field.frame(width: 220, height: 32), size: CGSize(width: 240, height: 40))
        field.keymapStore.lastError = nil
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
