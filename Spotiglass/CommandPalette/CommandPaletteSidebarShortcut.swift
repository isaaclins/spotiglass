import AppKit
import SwiftUI

/// The keyboard rules of Show/Hide Sidebar beyond its rebindable keymap chord (#436).
///
/// The View menu's own Show/Hide Sidebar item is replaced by the keymap command so the menu
/// shows ⌘S, but that system item carried ⌃⌘S, the standard Mac chord for the sidebar. It
/// stays as a fixed second chord, the way ⌘[ stays with Back.
@MainActor
enum CommandPaletteSidebarShortcut {
    static let systemKeystroke = "ctrl-cmd-s"

    /// True for a ⌃⌘S key press.
    static func isSystemChord(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              let pressed = CommandShortcut(event: event),
              let shortcut = try? CommandShortcut(keystroke: systemKeystroke)
        else { return false }
        return pressed == shortcut
    }

    /// True when a key press is meant for a text field (search, a playlist name) rather than
    /// for the sidebar. ⌘S does nothing in a text field, so firing there would only surprise.
    static func isTypingKeyPress(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        return event.window?.firstResponder is NSTextView
    }
}

/// ⌃⌘S for Settings' own sidebar. Main windows answer the chord in their key monitor, but
/// Settings has none, and once the system menu item was replaced nothing else did: with every
/// main window closed, ⌃⌘S reached nothing (#436). This answers it only in its own window.
struct SidebarSystemChordMonitor: NSViewRepresentable {
    /// Settings › Keyboard records ⌃⌘S as a binding then, so the chord must reach the recorder.
    var isRecordingHotkey: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isRecordingHotkey = isRecordingHotkey
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var isRecordingHotkey = false
        /// The system Show/Hide Sidebar action; a seam for tests.
        var sendSystemSidebarToggle: () -> Void = {
            NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
        }
        private var monitor: Any?

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return handled ? nil : event
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        /// True when the key press was ⌃⌘S in this view's window and it toggled the sidebar.
        func handle(_ event: NSEvent) -> Bool {
            guard !isRecordingHotkey, !event.isARepeat,
                  let window = view?.window, event.window === window,
                  CommandPaletteSidebarShortcut.isSystemChord(event),
                  !CommandPaletteSidebarShortcut.isTypingKeyPress(event)
            else { return false }
            sendSystemSidebarToggle()
            return true
        }
    }
}
