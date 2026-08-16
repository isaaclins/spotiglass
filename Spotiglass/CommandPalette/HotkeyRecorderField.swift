import AppKit
import SwiftUI

/// macOS key capture field (Raycast-style): click to focus, then press a shortcut.
struct HotkeyRecorderField: NSViewRepresentable {
    let commandID: String
    @ObservedObject var keymapStore: CommandPaletteKeymapStore
    var onRecordingChange: (Bool) -> Void
    /// Invoked when the chosen shortcut is already bound to another catalog command.
    var onCaptureConflict: (CommandShortcut, String) -> Void
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
        }

        func recordingBegan(in view: RecorderKeyContainerView) {
            teardownMonitors()
            parent.onRecordingChange(true)
            // Local event monitors destabilize the XCTest host on headless CI; key paths are
            // exercised via injected keyDown events in HotkeyRecorderFieldTests instead.
            guard !Self.isRunningUnderXCTest else { return }
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
                    parent.keymapStore.lastError = error.localizedDescription
                }
                view.finishRecordingAndResign()
                return
            }
            guard let shortcut = CommandShortcut(recordingKeyDown: event) else { return }
            do {
                try parent.keymapStore.setBinding(
                    commandID: parent.commandID,
                    shortcut: shortcut,
                    replaceConflicting: false
                )
                parent.onApplied()
                view.finishRecordingAndResign()
            } catch let conflict as KeymapConflictError {
                if case let .conflict(otherID) = conflict {
                    parent.onCaptureConflict(shortcut, otherID)
                }
                view.finishRecordingAndResign()
            } catch {
                parent.keymapStore.lastError = error.localizedDescription
                view.finishRecordingAndResign()
            }
        }
    }
}

@MainActor
final class RecorderKeyContainerView: NSView {
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

    override func keyDown(with event: NSEvent) {
        if isRecording {
            coordinator?.handleKeyDown(event, in: self)
            return
        }
        // Focused but not recording: Space or Return arms the field, the way
        // Space activates a focused button. Everything else, Tab included, is
        // left to AppKit so focus can move on.
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if mods.isEmpty, event.keyCode == 49 || event.keyCode == 36 || event.keyCode == 76 {
            beginRecordingFromUser()
            return
        }
        super.keyDown(with: event)
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
