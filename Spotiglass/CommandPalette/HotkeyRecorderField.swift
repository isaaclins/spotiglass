import AppKit
import SwiftUI

/// macOS key capture field (Raycast-style): click to focus, then press a shortcut.
struct HotkeyRecorderField: NSViewRepresentable {
    let commandID: String
    @ObservedObject var keymapStore: CommandPaletteKeymapStore
    var onRecordingChange: (Bool) -> Void
    /// Invoked when the chosen shortcut is already bound to another catalog command.
    var onCaptureConflict: (CommandShortcut, String) -> Void
    /// Invoked when a key event cannot be recorded and a reason should be shown
    /// next to the field instead of leaving the user with no feedback.
    var onCaptureFailure: (String) -> Void = { _ in }
    /// Invoked after a successful apply or clear from this field.
    var onApplied: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> RecorderKeyContainerView {
        let v = RecorderKeyContainerView()
        v.coordinator = context.coordinator
        return v
    }

    func updateNSView(_ nsView: RecorderKeyContainerView, context: Context) {
        context.coordinator.parent = self
        nsView.coordinator = context.coordinator
        nsView.syncFromStore()
    }

    static func dismantleNSView(_ nsView: RecorderKeyContainerView, coordinator: Coordinator) {
        coordinator.teardownMonitors()
    }

    @MainActor
    final class Coordinator {
        var parent: HotkeyRecorderField
        private var mouseMonitor: Any?
        private var flagsMonitor: Any?
        private var keyDownMonitor: Any?
        private var shouldSuspendMenuKeyEquivalents = false
        private var suspendedMenuKeyEquivalents: [(item: NSMenuItem, key: String, modifiers: NSEvent.ModifierFlags)] = []

        init(_ parent: HotkeyRecorderField) {
            self.parent = parent
        }

        func teardownMonitors() {
            if let mouseMonitor {
                NSEvent.removeMonitor(mouseMonitor)
            }
            mouseMonitor = nil
            if let flagsMonitor {
                NSEvent.removeMonitor(flagsMonitor)
            }
            flagsMonitor = nil
            if let keyDownMonitor {
                NSEvent.removeMonitor(keyDownMonitor)
            }
            keyDownMonitor = nil
            shouldSuspendMenuKeyEquivalents = false
            restoreMenuKeyEquivalents()
        }

        func recordingBegan(in view: RecorderKeyContainerView) {
            teardownMonitors()
            parent.onRecordingChange(true)
            // Local event monitors destabilize the XCTest host on headless CI; key paths are
            // exercised via injected keyDown events in HotkeyRecorderFieldTests instead.
            guard !Self.isRunningUnderXCTest else { return }
            shouldSuspendMenuKeyEquivalents = true
            suspendMenuKeyEquivalents()
            // SwiftUI may finish rebuilding its Commands menu on the next run
            // loop after the Settings state changes. Re-apply the suspension
            // after that rebuild so the menu cannot restore a live equivalent.
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                guard self.shouldSuspendMenuKeyEquivalents, view.isRecording else { return }
                self.suspendMenuKeyEquivalents()
            }
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak view] event in
                guard let view, view.isRecording else { return event }
                guard event.window === view.window else { return event }
                let p = view.convert(event.locationInWindow, from: nil)
                if !view.bounds.contains(p) {
                    Task { @MainActor in
                        view.cancelRecording()
                    }
                }
                return event
            }
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak view] event in
                guard let view, view.isRecording else { return event }
                Task { @MainActor in
                    view.updateLiveModifierChips(event.modifierFlags)
                }
                return event
            }
            // AppKit checks menu key equivalents before it sends keyDown to the
            // first responder. Handle the event at the local-monitor boundary
            // while this field is armed, so a live menu chord such as Cmd-R or
            // Cmd-K cannot be swallowed by NSMenu first.
            keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
                guard let self, let view else { return event }
                let handled = MainActor.assumeIsolated {
                    guard let window = view.window,
                          view.isRecording,
                          window.isKeyWindow,
                          event.window == nil || event.window === window
                    else { return false }
                    self.handleKeyDown(event, in: view)
                    return true
                }
                return handled ? nil : event
            }
        }

        private func suspendMenuKeyEquivalents() {
            guard let mainMenu = NSApp.mainMenu else { return }
            for item in menuItems(in: mainMenu) where !item.keyEquivalent.isEmpty {
                if !suspendedMenuKeyEquivalents.contains(where: { $0.item === item }) {
                    suspendedMenuKeyEquivalents.append(
                        (item: item, key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask)
                    )
                }
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
            }
        }

        private func restoreMenuKeyEquivalents() {
            for suspended in suspendedMenuKeyEquivalents {
                suspended.item.keyEquivalent = suspended.key
                suspended.item.keyEquivalentModifierMask = suspended.modifiers
            }
            suspendedMenuKeyEquivalents.removeAll()
        }

        private func menuItems(in menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { item in
                [item] + (item.submenu.map(menuItems(in:)) ?? [])
            }
        }

        func recordingEnded() {
            teardownMonitors()
            parent.onRecordingChange(false)
        }

        private static var isRunningUnderXCTest: Bool {
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        }

        func handleKeyDown(_ event: NSEvent, in view: RecorderKeyContainerView) {
            if event.keyCode == 53 {
                view.cancelRecording()
                return
            }
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            // Plain Tab leaves the field. Recording swallows every other key, so
            // without this the control is a focus trap: Tab would be assigned to
            // the command rather than moving on (#128).
            if event.keyCode == 48, mods.subtracting(.shift).isEmpty {
                view.endRecordingKeepingFocus()
                view.moveFocus(backwards: mods.contains(.shift))
                return
            }
            if (event.keyCode == 51 || event.keyCode == 117), mods.isEmpty {
                do {
                    try parent.keymapStore.clearBinding(commandID: parent.commandID)
                    parent.onApplied()
                } catch {
                    let message = CommandPaletteKeymapErrorPresenter.message(
                        for: error,
                        source: parent.keymapStore.fileURL.path,
                        operation: "clear shortcut"
                    )
                    parent.keymapStore.lastError = message
                    parent.onCaptureFailure(message)
                }
                view.finishRecordingAndResign()
                return
            }
            guard let shortcut = CommandShortcut(recordingKeyDown: event) else {
                let message = SpotiglassL10n.string("palette.settings.recordingUnsupported")
                parent.keymapStore.lastError = message
                parent.onCaptureFailure(message)
                view.finishRecordingAndResign()
                return
            }
            do {
                try parent.keymapStore.setBinding(
                    commandID: parent.commandID,
                    shortcut: shortcut,
                    replaceConflicting: false
                )
                parent.onApplied()
                view.finishRecordingAndResign()
            } catch let conflict as KeymapConflictError {
                switch conflict {
                case let .conflict(otherID):
                    parent.onCaptureConflict(shortcut, otherID)
                case .reservedByMenuItem:
                    let message = CommandPaletteKeymapErrorPresenter.message(
                        for: conflict,
                        source: parent.keymapStore.fileURL.path,
                        operation: "record shortcut"
                    )
                    parent.keymapStore.lastError = message
                    parent.onCaptureFailure(message)
                }
                view.finishRecordingAndResign()
            } catch {
                let message = CommandPaletteKeymapErrorPresenter.message(
                    for: error,
                    source: parent.keymapStore.fileURL.path,
                    operation: "record shortcut"
                )
                parent.keymapStore.lastError = message
                parent.onCaptureFailure(message)
                view.finishRecordingAndResign()
            }
        }
    }
}

@MainActor
final class RecorderKeyContainerView: NSView, FocusedKeyEventOwner {
    weak var coordinator: HotkeyRecorderField.Coordinator?
    private let button = NSButton(title: "", target: nil, action: nil)
    private(set) var isRecording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        button.isBordered = true
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.target = self
        button.action = #selector(clicked)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    @objc private func clicked() {
        _ = window?.makeFirstResponder(self)
        beginRecordingFromUser()
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        _ = window?.makeFirstResponder(self)
        beginRecordingFromUser()
    }

    // Focus alone does not record. Arriving here by Tab used to start capture,
    // so a keyboard user could not pass through the field without binding a key
    // to the command (#128). Recording starts on a click or on Space/Return,
    // which is how a control this destructive should be armed.
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            syncFromStore()
        }
        return ok
    }

    /// Hands focus to the next (or previous) control, so Tab behaves the way it
    /// does everywhere else in the window. A window with no other key view has
    /// nowhere to send focus, and asking anyway is not worth a crash.
    func moveFocus(backwards: Bool) {
        guard let window, window.firstResponder === self else { return }
        guard nextValidKeyView != nil || previousValidKeyView != nil else { return }
        if backwards {
            window.selectPreviousKeyView(self)
        } else {
            window.selectNextKeyView(self)
        }
    }

    /// Stops capture but stays focused, so the key-view loop can move focus
    /// itself rather than having it dropped first.
    func endRecordingKeepingFocus() {
        guard isRecording else { return }
        isRecording = false
        coordinator?.recordingEnded()
        syncFromStore()
    }

    private func beginRecordingFromUser() {
        guard !isRecording else { return }
        isRecording = true
        updateLiveModifierChips(NSEvent.modifierFlags)
        coordinator?.recordingBegan(in: self)
    }

    override func resignFirstResponder() -> Bool {
        let wasRecording = isRecording
        let ok = super.resignFirstResponder()
        if ok, wasRecording {
            finishRecordingAfterResign()
        }
        return ok
    }

    func cancelRecording() {
        finishRecordingAndResign()
    }

    /// Test hook: drive ``HotkeyRecorderField.Coordinator/handleKeyDown(_:in:)`` without key-window
    /// first-responder churn (unreliable on headless CI runners).
    // swift-format-ignore: AlwaysUseLowerCamelCase
    // The `testing_` prefix marks this as a test-only seam at the call site.
    func testing_beginKeyCapture() {
        guard !isRecording else { return }
        isRecording = true
        updateLiveModifierChips(NSEvent.modifierFlags)
        coordinator?.recordingBegan(in: self)
    }

    func finishRecordingAndResign() {
        guard isRecording else { return }
        isRecording = false
        coordinator?.recordingEnded()
        syncFromStore()
        if window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        }
    }

    private func finishRecordingAfterResign() {
        guard coordinator != nil else { return }
        isRecording = false
        coordinator?.recordingEnded()
        syncFromStore()
    }

    func ownsKeyEvent(_ event: NSEvent) -> Bool {
        if isRecording {
            return true
        }
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        return mods.isEmpty && Self.isArmingKeyCode(event.keyCode)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, let coordinator else {
            return super.performKeyEquivalent(with: event)
        }
        // This is a second line of defense for paths that reach the responder
        // chain without passing through the recorder's local monitor. The local
        // monitor is what wins against an actual matching menu item.
        coordinator.handleKeyDown(event, in: self)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if isRecording {
            coordinator?.handleKeyDown(event, in: self)
            return
        }
        // Focused but not recording: Space or Return arms the field, the way
        // Space activates a focused button. Everything else, Tab included, is
        // left to AppKit so focus can move on.
        if ownsKeyEvent(event) {
            beginRecordingFromUser()
            return
        }
        super.keyDown(with: event)
    }

    private static func isArmingKeyCode(_ keyCode: UInt16) -> Bool {
        keyCode == 49 || keyCode == 36 || keyCode == 76
    }

    func updateLiveModifierChips(_ flags: NSEvent.ModifierFlags) {
        guard isRecording else { return }
        let f = flags.intersection([.command, .control, .option, .shift])
        var parts: [String] = []
        if f.contains(.control) { parts.append("⌃") }
        if f.contains(.option) { parts.append("⌥") }
        if f.contains(.shift) { parts.append("⇧") }
        if f.contains(.command) { parts.append("⌘") }
        let mod = parts.joined(separator: " ")
        let recording = SpotiglassL10n.string("palette.hotkeyRecorder.recording")
        button.title = mod.isEmpty ? recording : "\(recording)  \(mod)"
    }

    func syncFromStore() {
        guard let coordinator else { return }
        let store = coordinator.parent.keymapStore
        let id = coordinator.parent.commandID
        if isRecording { return }
        if let sc = store.primaryShortcut(for: id) {
            button.title = sc.displayChips.joined(separator: " ")
        } else {
            button.title = SpotiglassL10n.string("palette.hotkeyRecorder.clickToRecord")
        }
    }
}
