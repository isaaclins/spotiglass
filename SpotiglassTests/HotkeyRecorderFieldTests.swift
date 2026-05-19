import AppKit
import SwiftUI
import XCTest
@testable import Spotiglass

@MainActor
final class HotkeyRecorderFieldTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.close() }
        windows.removeAll()
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
        HotkeyRecorderField.Coordinator
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
        return (field, keymap, view, coordinator)
    }

    func testRecordingShowsModifierChipsAndEndsOnEscape() throws {
        var recording = false
        let (_, _, view, _) = try makeHarness(onRecordingChange: { recording = $0 })
        XCTAssertTrue(view.becomeFirstResponder())
        XCTAssertTrue(view.isRecording)
        XCTAssertTrue(recording)

        view.updateLiveModifierChips([.command, .shift])
        XCTAssertTrue(view.subviews.first(where: { $0 is NSButton }) is NSButton)

        let escape = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 53
        )!
        view.keyDown(with: escape)
        XCTAssertFalse(view.isRecording)
        XCTAssertFalse(recording)
    }

    func testDeleteClearsBindingAndApplies() throws {
        var applied = 0
        let (field, keymap, view, _) = try makeHarness(onApplied: { applied += 1 })
        let shortcut = try CommandShortcut(keystroke: "shift-cmd-0")
        try keymap.setBinding(commandID: field.commandID, shortcut: shortcut, replaceConflicting: true)
        view.syncFromStore()

        XCTAssertTrue(view.becomeFirstResponder())
        let delete = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 51
        )!
        view.keyDown(with: delete)
        XCTAssertEqual(applied, 1)
        XCTAssertNil(keymap.primaryShortcut(for: field.commandID))
        XCTAssertFalse(view.isRecording)
    }

    func testCaptureShortcutAppliesBinding() throws {
        var applied = 0
        let (field, keymap, view, _) = try makeHarness(onApplied: { applied += 1 })
        XCTAssertTrue(view.becomeFirstResponder())

        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            characters: "9",
            charactersIgnoringModifiers: "9",
            isARepeat: false,
            keyCode: 25
        )!
        view.keyDown(with: event)
        XCTAssertEqual(applied, 1)
        XCTAssertNotNil(keymap.primaryShortcut(for: field.commandID))
    }

    func testCaptureConflictInvokesCallback() throws {
        var conflict: (CommandShortcut, String)?
        let stolen = try CommandShortcut(keystroke: "cmd-k")
        let (field, keymap, view, _) = try makeHarness(
            commandID: CommandPaletteCommandID.openSettings,
            onCaptureConflict: { shortcut, otherID in conflict = (shortcut, otherID) }
        )
        try keymap.setBinding(
            commandID: CommandPaletteCommandID.openPalette,
            shortcut: stolen,
            replaceConflicting: true
        )
        XCTAssertTrue(view.becomeFirstResponder())

        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            characters: "k",
            charactersIgnoringModifiers: "k",
            isARepeat: false,
            keyCode: 40
        )!
        view.keyDown(with: event)
        XCTAssertEqual(conflict?.1, CommandPaletteCommandID.openPalette)
        XCTAssertNil(keymap.primaryShortcut(for: field.commandID))
    }

    func testCoordinatorTeardownAfterRecording() throws {
        var recording = false
        let (_, _, view, coordinator) = try makeHarness(onRecordingChange: { recording = $0 })
        XCTAssertTrue(view.becomeFirstResponder())
        XCTAssertTrue(recording)
        coordinator.recordingEnded()
        XCTAssertFalse(recording)
        coordinator.teardownMonitors()
        view.cancelRecording()
        XCTAssertFalse(view.isRecording)
    }

    func testSwiftUIHostInspects() throws {
        let (_, keymap, _, _) = try makeHarness()
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
