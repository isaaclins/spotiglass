import AppKit

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
