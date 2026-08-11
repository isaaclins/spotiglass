import AppKit
import SwiftUI

extension CommandPaletteKeymapStore {
    /// The key equivalent the menu bar should show for a catalog command, taken
    /// from the user's current keymap rather than hardcoded, so rebinding a
    /// command in Settings → Keyboard moves its menu shortcut with it instead of
    /// leaving a second, stale chord alive in the menu bar.
    ///
    /// Returns `nil` when the command has no binding, or only bindings that must
    /// not become menu key equivalents (see ``CommandShortcut/menuKeyboardShortcut``).
    func menuShortcut(for commandID: String) -> KeyboardShortcut? {
        let chords = bindings
            .filter { _, boundCommands in boundCommands.contains { $0.command == commandID } }
            .map(\.key)
        // `bindings` is a dictionary, so sort before picking to keep the menu
        // stable when one command carries several chords.
        let ordered = chords.sorted { lhs, rhs in
            ((try? lhs.canonicalToken()) ?? "") < ((try? rhs.canonicalToken()) ?? "")
        }
        return ordered.compactMap(\.menuKeyboardShortcut).first
    }
}

extension CommandShortcut {
    /// This chord as a SwiftUI menu key equivalent, or `nil` when it has to stay
    /// with the in-app event monitor.
    ///
    /// AppKit matches menu key equivalents before the key reaches the focused
    /// view, so a chord without ⌘, ⌃ or ⌥ would swallow ordinary typing: the
    /// default bare Space binding for Play/Pause would fire instead of inserting
    /// a space in the palette's search field. Bare keys therefore stay with
    /// ``CommandPaletteManager/handleKeyEvent(_:)``, which skips text input
    /// first, and the menu shows no shortcut for them.
    var menuKeyboardShortcut: KeyboardShortcut? {
        guard !modifiers.intersection([.command, .control, .option]).isEmpty else { return nil }
        guard key.count == 1, let character = key.first else { return nil }

        var eventModifiers: EventModifiers = []
        if modifiers.contains(.command) { eventModifiers.insert(.command) }
        if modifiers.contains(.control) { eventModifiers.insert(.control) }
        if modifiers.contains(.option) { eventModifiers.insert(.option) }
        if modifiers.contains(.shift) { eventModifiers.insert(.shift) }
        return KeyboardShortcut(KeyEquivalent(character), modifiers: eventModifiers)
    }
}
