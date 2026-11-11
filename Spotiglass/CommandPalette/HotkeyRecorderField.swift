import AppKit
import SwiftUI

/// macOS key capture field (Raycast-style): an empty field says "Record Shortcut",
/// recording shows the keys held as key caps, and a valid chord saves at once.
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
    /// The chord the row reports a conflict for. The field shows it in place of
    /// the saved one, so the problem reads on the field that has it (#541).
    var conflictingShortcut: CommandShortcut? = nil
    /// Draws the field's problem state while its row shows a conflict or a
    /// reason the last key press couldn't be used.
    var showsProblem: Bool = false

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
        nsView.conflictingShortcut = conflictingShortcut
        nsView.showsProblem = showsProblem
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
                view.finishRecordingAndResign()
                clearBinding()
                return
            }
            // A key that can't be used keeps the field recording, with the
            // reason on its row, so the next try is one key press away (#541).
            guard let shortcut = CommandShortcut(recordingKeyDown: event) else {
                let message = SpotiglassL10n.string("palette.settings.recordingUnsupported")
                parent.keymapStore.lastError = message
                parent.onCaptureFailure(message)
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
                    // Ends recording: Replace on the row is the next step.
                    view.finishRecordingAndResign()
                    parent.onCaptureConflict(shortcut, otherID)
                case .reservedByMenuItem:
                    // Like an unusable key: say why on the row, keep recording.
                    let message = CommandPaletteKeymapErrorPresenter.message(
                        for: conflict,
                        source: parent.keymapStore.fileURL.path,
                        operation: "record shortcut"
                    )
                    parent.keymapStore.lastError = message
                    parent.onCaptureFailure(message)
                }
            } catch {
                view.finishRecordingAndResign()
                let message = CommandPaletteKeymapErrorPresenter.message(
                    for: error,
                    source: parent.keymapStore.fileURL.path,
                    operation: "record shortcut"
                )
                parent.keymapStore.lastError = message
                parent.onCaptureFailure(message)
            }
        }

        /// Shared by Delete while recording and the clear control on the field.
        func clearBinding() {
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
        }
    }
}

/// What a shortcut field shows: key caps, or a prompt in their place.
enum RecorderFieldContent: Equatable {
    case keys([String])
    case prompt(String)
}

/// The shortcut field in Settings > Keyboard. It draws itself like Raycast's
/// hotkey column (#541): an empty field says what to do, a bound one shows its
/// chord as key caps with a clear control on the field, and while recording it
/// shows the modifiers being held, live.
@MainActor
final class RecorderKeyContainerView: NSView, FocusedKeyEventOwner {
    weak var coordinator: HotkeyRecorderField.Coordinator?
    private let clearButton = NSButton()
    private(set) var isRecording = false
    private var liveModifiers: NSEvent.ModifierFlags = []

    var conflictingShortcut: CommandShortcut? {
        didSet { if conflictingShortcut != oldValue { refresh() } }
    }

    var showsProblem = false {
        didSet { if showsProblem != oldValue { refresh() } }
    }

    private static let cornerRadius: CGFloat = 6
    private static let capHeight: CGFloat = 18
    private static let capMinWidth: CGFloat = 20
    private static let capSpacing: CGFloat = 3
    private static let capFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .medium)
    private static let promptFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize + 1)
    static let clearSize: CGFloat = 18
    static let inset: CGFloat = 6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .default
        let symbol = NSImage.SymbolConfiguration(pointSize: NSFont.smallSystemFontSize + 1, weight: .regular)
            .applying(.init(hierarchicalColor: .secondaryLabelColor))
        clearButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: SpotiglassL10n.string("a11y.palette.clearShortcut")
        )?.withSymbolConfiguration(symbol)
        clearButton.isBordered = false
        clearButton.imagePosition = .imageOnly
        clearButton.target = self
        clearButton.action = #selector(clearClicked)
        clearButton.refusesFirstResponder = true
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clearButton)
        NSLayoutConstraint.activate([
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset + 1),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: Self.clearSize),
            clearButton.heightAnchor.constraint(equalToConstant: Self.clearSize),
            heightAnchor.constraint(greaterThanOrEqualToConstant: SpotiglassDesign.Layout.shortcutFieldMinHeight),
        ])
        clearButton.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    // MARK: State shown

    private var savedShortcut: CommandShortcut? {
        guard let coordinator else { return nil }
        return coordinator.parent.keymapStore.primaryShortcut(for: coordinator.parent.commandID)
    }

    /// What the field shows right now. Recording wins, then a pending conflict,
    /// then the saved chord.
    var content: RecorderFieldContent {
        if isRecording {
            let held = Self.modifierChips(liveModifiers)
            return held.isEmpty ? .prompt(SpotiglassL10n.string("palette.hotkeyRecorder.recording")) : .keys(held)
        }
        if let shortcut = conflictingShortcut ?? savedShortcut {
            return .keys(shortcut.displayChips)
        }
        return .prompt(SpotiglassL10n.string("palette.hotkeyRecorder.clickToRecord"))
    }

    /// The clear control sits on the field while there is a saved chord to clear.
    var showsClearControl: Bool {
        !isRecording && conflictingShortcut == nil && savedShortcut != nil
    }

    private static func modifierChips(_ flags: NSEvent.ModifierFlags) -> [String] {
        let f = flags.intersection([.command, .control, .option, .shift])
        var parts: [String] = []
        if f.contains(.control) { parts.append("⌃") }
        if f.contains(.option) { parts.append("⌥") }
        if f.contains(.shift) { parts.append("⇧") }
        if f.contains(.command) { parts.append("⌘") }
        return parts
    }

    private func refresh() {
        clearButton.isHidden = !showsClearControl
        // Read on every refresh so a live language switch reaches them.
        clearButton.toolTip = SpotiglassL10n.string("palette.settings.clearShortcut")
        clearButton.setAccessibilityLabel(SpotiglassL10n.string("a11y.palette.clearShortcut"))
        toolTip = SpotiglassL10n.string("palette.hotkeyRecorder.hint")
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    func syncFromStore() {
        refresh()
    }

    func updateLiveModifierChips(_ flags: NSEvent.ModifierFlags) {
        guard isRecording else { return }
        liveModifiers = flags.intersection([.command, .control, .option, .shift])
        refresh()
    }

    // MARK: Drawing

    private static let promptAttributes: [NSAttributedString.Key: Any] = [.font: promptFont]
    private static let capAttributes: [NSAttributedString.Key: Any] = [.font: capFont]

    private static func capWidths(_ chips: [String]) -> [CGFloat] {
        chips.map { max(capMinWidth, ($0 as NSString).size(withAttributes: capAttributes).width + 10) }
    }

    /// Width the content takes inside the field. The field has one width in
    /// every row and language, so the widest state has to fit with the insets
    /// and the clear control beside saved keys (checked per language in tests).
    static func contentWidth(for content: RecorderFieldContent) -> CGFloat {
        switch content {
        case let .prompt(text):
            return (text as NSString).size(withAttributes: promptAttributes).width
        case let .keys(chips):
            return capWidths(chips).reduce(0, +) + capSpacing * CGFloat(max(0, chips.count - 1))
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let field = bounds.insetBy(dx: 0.75, dy: 0.75)
        let path = NSBezierPath(roundedRect: field, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        let accent = NSColor.controlAccentColor
        let problem = showsProblem && !isRecording
        (isRecording ? accent.withAlphaComponent(0.12) : NSColor.labelColor.withAlphaComponent(0.05)).setFill()
        path.fill()
        let border: NSColor = problem ? .systemOrange : (isRecording ? accent : .separatorColor)
        border.setStroke()
        path.lineWidth = (problem || isRecording) ? 1.5 : 1
        path.stroke()

        var area = bounds.insetBy(dx: Self.inset, dy: 0)
        if showsClearControl {
            area.size.width -= Self.clearSize
        }
        switch content {
        case let .prompt(text):
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Self.promptFont,
                .foregroundColor: isRecording ? accent : NSColor.secondaryLabelColor,
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            let origin = NSPoint(x: area.midX - Self.contentWidth(for: content) / 2, y: area.midY - size.height / 2)
            (text as NSString).draw(at: origin, withAttributes: attributes)
        case let .keys(chips):
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Self.capFont,
                .foregroundColor: problem ? NSColor.systemOrange : NSColor.labelColor,
            ]
            let widths = Self.capWidths(chips)
            var x = area.midX - Self.contentWidth(for: content) / 2
            let y = area.midY - Self.capHeight / 2
            for (chip, width) in zip(chips, widths) {
                let cap = NSRect(x: x, y: y, width: width, height: Self.capHeight)
                (problem ? NSColor.systemOrange.withAlphaComponent(0.14) : NSColor.labelColor.withAlphaComponent(isRecording ? 0.14 : 0.09)).setFill()
                NSBezierPath(roundedRect: cap, xRadius: 4, yRadius: 4).fill()
                let size = (chip as NSString).size(withAttributes: attributes)
                (chip as NSString).draw(
                    at: NSPoint(x: cap.midX - size.width / 2, y: cap.midY - size.height / 2),
                    withAttributes: attributes
                )
                x += width + Self.capSpacing
            }
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).fill()
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityLabel() -> String? {
        switch content {
        case let .keys(chips): chips.joined(separator: " ")
        case let .prompt(text): text
        }
    }

    override func accessibilityHelp() -> String? {
        SpotiglassL10n.string("palette.hotkeyRecorder.hint")
    }

    override func accessibilityPerformPress() -> Bool {
        _ = window?.makeFirstResponder(self)
        beginRecordingFromUser()
        return true
    }

    override func accessibilityChildren() -> [Any]? {
        showsClearControl ? [clearButton] : []
    }

    // MARK: Interaction

    @objc private func clearClicked() {
        coordinator?.clearBinding()
        refresh()
    }

    override func mouseDown(with event: NSEvent) {
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
        liveModifiers = []
        coordinator?.recordingBegan(in: self)
        updateLiveModifierChips(NSEvent.modifierFlags)
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
        beginRecordingFromUser()
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
}
