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
            AppKitTestSupport.closeWindowSafely(window)
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
        onCaptureFailure: @escaping (String) -> Void = { _ in },
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
            onCaptureFailure: onCaptureFailure,
            onApplied: onApplied
        )
        let coordinator = HotkeyRecorderField.Coordinator(field)
        let view = RecorderKeyContainerView(frame: NSRect(x: 0, y: 0, width: 220, height: 32))
        view.coordinator = coordinator
        var window: NSWindow?
        if attachWindow {
            let w = OffscreenTestWindow(
                contentRect: NSRect(x: 0, y: 0, width: 240, height: 40),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            w.isReleasedWhenClosed = false
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

    /// A key that can't be used says why and keeps recording, so the next
    /// press is the next try, and a valid chord after it saves at once (#541).
    func testUnsupportedRecordedEventShowsReasonAndKeepsRecording() throws {
        var failure: String?
        var applied = 0
        let (_, keymap, view, _, _) = try makeHarness(
            onCaptureFailure: { failure = $0 },
            onApplied: { applied += 1 }
        )

        view.testing_beginKeyCapture()
        // A modifier-only key-down cannot become a CommandShortcut.
        view.keyDown(with: keyEvent(virtualKey: 55, modifierFlags: [.command]))

        XCTAssertTrue(view.isRecording)
        XCTAssertEqual(failure, SpotiglassL10n.string("palette.settings.recordingUnsupported"))
        XCTAssertEqual(keymap.lastError, failure)

        view.keyDown(with: keyEvent(virtualKey: 38, modifierFlags: [.control, .option]))
        XCTAssertFalse(view.isRecording)
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(keymap.primaryShortcut(for: CommandPaletteCommandID.openSettings), try CommandShortcut(keystroke: "ctrl-alt-j"))
    }

    func testMenuOwnedShortcutShowsReasonAndKeepsRecording() throws {
        var failure: String?
        let (_, _, view, _, _) = try makeHarness(
            onCaptureFailure: { failure = $0 }
        )
        view.testing_beginKeyCapture()
        view.keyDown(with: keyEvent(virtualKey: 124, modifierFlags: [.command]))

        XCTAssertTrue(view.isRecording)
        XCTAssertEqual(
            failure,
            SpotiglassL10n.format(
                "keymap.conflict.menuItem",
                SpotiglassL10n.string("menu.playback.seekForward")
            )
        )
    }

    /// The field used to be a grey button reading "Click to record" under an
    /// instruction line. It now says what to do itself, shows the keys being
    /// held as key caps while recording, and the saved chord after (#541).
    func testFieldShowsWhatToDoAndTheKeysHeldWhileRecording() throws {
        let (field, keymap, view, _, _) = try makeHarness()
        try keymap.clearBinding(commandID: field.commandID)
        view.syncFromStore()
        XCTAssertEqual(view.content, .prompt(SpotiglassL10n.string("palette.hotkeyRecorder.clickToRecord")))
        XCTAssertEqual(SpotiglassL10n.string("palette.hotkeyRecorder.clickToRecord", locale: Locale(identifier: "en")), "Record Shortcut")
        XCTAssertFalse(view.showsClearControl, "nothing to clear")

        view.testing_beginKeyCapture()
        view.updateLiveModifierChips([])
        XCTAssertEqual(view.content, .prompt(SpotiglassL10n.string("palette.hotkeyRecorder.recording")))
        view.updateLiveModifierChips([.command])
        XCTAssertEqual(view.content, .keys(["⌘"]))
        view.updateLiveModifierChips([.command, .shift, .function])
        XCTAssertEqual(view.content, .keys(["⇧", "⌘"]), "live, in Mac order, only the four modifiers")

        view.keyDown(with: keyEvent(virtualKey: 40, modifierFlags: [.control, .option]))
        XCTAssertFalse(view.isRecording, "a valid chord saves at once")
        XCTAssertEqual(view.content, .keys(["⌃", "⌥", "K"]))
        XCTAssertTrue(view.showsClearControl)
        XCTAssertEqual(view.accessibilityRole(), .button)
        XCTAssertEqual(view.accessibilityLabel(), "⌃ ⌥ K")
        XCTAssertEqual(view.accessibilityHelp(), SpotiglassL10n.string("palette.hotkeyRecorder.hint"))
    }

    /// Clearing used to be a separate button beside the field. It is now a
    /// small control on the field itself, also reachable by VoiceOver.
    func testClearControlOnTheFieldClearsTheShortcut() throws {
        var applied = 0
        let (field, keymap, view, _, _) = try makeHarness(onApplied: { applied += 1 })
        try keymap.setBinding(commandID: field.commandID, shortcut: try CommandShortcut(keystroke: "ctrl-k"), replaceConflicting: true)
        view.syncFromStore()

        let clear = try XCTUnwrap(view.subviews.compactMap { $0 as? NSButton }.first)
        XCTAssertFalse(clear.isHidden)
        XCTAssertEqual(clear.accessibilityLabel(), SpotiglassL10n.string("a11y.palette.clearShortcut"))
        // VoiceOver gets the button itself, named, not a nameless group around it.
        let children = view.accessibilityChildren() ?? []
        XCTAssertEqual(children.count, 1)
        let element = try XCTUnwrap(children.first as? NSAccessibilityProtocol)
        XCTAssertEqual(element.accessibilityRole(), .button)
        XCTAssertEqual(element.accessibilityLabel(), SpotiglassL10n.string("a11y.palette.clearShortcut"))
        clear.performClick(nil)

        XCTAssertNil(keymap.primaryShortcut(for: field.commandID))
        XCTAssertEqual(applied, 1)
        XCTAssertTrue(clear.isHidden, "nothing left to clear")
        XCTAssertEqual(view.accessibilityChildren()?.count, 0)
        XCTAssertEqual(view.content, .prompt(SpotiglassL10n.string("palette.hotkeyRecorder.clickToRecord")))
    }

    /// SwiftUI updates every field on each change in the pane, a search
    /// keystroke included. VoiceOver hears about a field only when what it
    /// reads out changes, not once per row per keystroke.
    func testFieldTellsVoiceOverOnlyWhenWhatItReadsChanges() throws {
        let (field, keymap, view, _, _) = try makeHarness()
        view.syncFromStore()
        let settled = view.accessibilityChangeCount
        for _ in 0..<5 {
            view.syncFromStore()
        }
        XCTAssertEqual(view.accessibilityChangeCount, settled, "unchanged field, no notice")

        try keymap.setBinding(commandID: field.commandID, shortcut: try CommandShortcut(keystroke: "ctrl-k"), replaceConflicting: true)
        view.syncFromStore()
        view.syncFromStore()
        XCTAssertEqual(view.accessibilityChangeCount, settled + 1, "one notice for the new shortcut")
    }

    /// A taken chord shows on the field that was recording, in its problem
    /// state, and the row names the command that has it.
    func testConflictShowsTheTakenChordOnTheField() throws {
        let stolen = try CommandShortcut(keystroke: "ctrl-j")
        var conflict: (CommandShortcut, String)?
        let (_, keymap, view, _, _) = try makeHarness(onCaptureConflict: { conflict = ($0, $1) })
        try keymap.setBinding(commandID: CommandPaletteCommandID.openPalette, shortcut: stolen, replaceConflicting: true)

        view.testing_beginKeyCapture()
        view.keyDown(with: try keyEvent(for: stolen))
        XCTAssertEqual(conflict?.1, CommandPaletteCommandID.openPalette)
        // What the Settings row hands back to its field while the conflict stands.
        view.conflictingShortcut = conflict?.0
        view.showsProblem = true
        XCTAssertEqual(view.content, .keys(["⌃", "J"]))
        XCTAssertFalse(view.showsClearControl, "Replace on the row is the way out, not clear")
        let otherTitle = CommandPaletteCommandCatalog.editable.first { $0.commandID == CommandPaletteCommandID.openPalette }!.title
        XCTAssertTrue(SpotiglassL10n.format("palette.settings.conflict", otherTitle).contains(otherTitle))
    }

    func testRecordingKeyEquivalentRoutesToRecorder() throws {
        var applied = 0
        let (_, keymap, view, _, _) = try makeHarness(onApplied: { applied += 1 })
        let event = keyEvent(virtualKey: 9, modifierFlags: [.control])

        view.testing_beginKeyCapture()
        XCTAssertTrue(view.performKeyEquivalent(with: event))

        XCTAssertEqual(applied, 1)
        let recorded = keymap.primaryShortcut(for: CommandPaletteCommandID.openSettings)
        XCTAssertEqual(recorded, try CommandShortcut(keystroke: "ctrl-v"))
        XCTAssertFalse(view.isRecording)
    }

    func testRecordingNumericShortcutsOneThroughFivePersistsBindings() throws {
        let numericKeys: [(digit: String, virtualKey: CGKeyCode)] = [
            ("1", 18),
            ("2", 19),
            ("3", 20),
            ("4", 21),
            ("5", 23),
        ]
        let (_, keymap, view, _, _) = try makeHarness()

        for (digit, virtualKey) in numericKeys {
            view.testing_beginKeyCapture()
            view.keyDown(with: keyEvent(virtualKey: virtualKey, modifierFlags: [.command, .shift]))

            XCTAssertEqual(
                keymap.primaryShortcut(for: CommandPaletteCommandID.openSettings),
                try CommandShortcut(keystroke: "shift-cmd-\(digit)"),
                "recording \(digit) should persist the physical numeric key with modifiers"
            )
            XCTAssertFalse(view.isRecording, "recording \(digit) should finish normally")
        }
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

    /// Focus alone used to start capture, so Tab into the field then Tab again
    /// bound Tab to the command instead of moving on (#128).
    func testFocusDoesNotRecordAndTabLeavesTheField() throws {
        var recording = false
        var applied = 0
        // No real key window here: this suite drives the field through its test
        // seam because first-responder churn destabilizes the XCTest host.
        let (_, keymap, view, _, _) = try makeHarness(
            onRecordingChange: { recording = $0 },
            onApplied: { applied += 1 }
        )

        let original = keymap.primaryShortcut(for: CommandPaletteCommandID.openSettings)
        _ = view.becomeFirstResponder()
        XCTAssertFalse(view.isRecording, "focus alone must not arm the recorder")
        XCTAssertFalse(recording)

        // Tab while focused but not recording is left to AppKit.
        view.keyDown(with: keyEvent(virtualKey: 48))
        XCTAssertFalse(view.isRecording)
        XCTAssertEqual(
            keymap.primaryShortcut(for: CommandPaletteCommandID.openSettings),
            original,
            "tabbing through must not change the binding"
        )
        XCTAssertEqual(applied, 0, "tabbing through must not write a binding")

        // Space arms it, the way Space activates a focused button.
        view.keyDown(with: keyEvent(virtualKey: 49))
        XCTAssertTrue(view.isRecording, "Space must arm the recorder")
        XCTAssertTrue(recording)

        // Tab while recording leaves rather than binding Tab.
        view.keyDown(with: keyEvent(virtualKey: 48))
        XCTAssertFalse(view.isRecording)
        XCTAssertEqual(keymap.primaryShortcut(for: CommandPaletteCommandID.openSettings), original)
        XCTAssertEqual(applied, 0)
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
