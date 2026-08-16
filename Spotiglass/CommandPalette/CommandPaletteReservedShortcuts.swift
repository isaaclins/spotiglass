import Foundation

/// Chords that menu items claim directly, outside the rebindable keymap.
///
/// The app-wide key monitor sees an event before AppKit dispatches it to the
/// menu and swallows anything it matches, so a user-assigned chord that equals
/// one of these would shadow the menu item while the menu kept advertising it.
/// The keymap store refuses those bindings, which is only possible if the list
/// of menu-owned chords lives in one place.
///
/// A command belongs here only while its menu item hardcodes
/// `.keyboardShortcut(...)`. The moment an item derives its key equivalent from
/// the keymap, the ordinary conflict check covers it and the entry must go.
enum CommandPaletteReservedShortcuts {
    struct Reservation {
        let keystroke: String
        /// Catalog key for the menu item's title, used to name the conflict.
        let menuTitleKey: String
    }

    static let all: [Reservation] = [
        Reservation(keystroke: "cmd-[", menuTitleKey: "menu.view.back"),
        Reservation(keystroke: "alt-cmd-s", menuTitleKey: "menu.playback.shuffle"),
        Reservation(keystroke: "alt-cmd-r", menuTitleKey: "menu.playback.repeat"),
        Reservation(keystroke: "cmd-right", menuTitleKey: "menu.playback.seekForward"),
        Reservation(keystroke: "cmd-left", menuTitleKey: "menu.playback.seekBackward"),
        Reservation(keystroke: "alt-cmd-e", menuTitleKey: "browser.addToQueue"),
        Reservation(keystroke: "alt-cmd-p", menuTitleKey: "browser.pin"),
    ]

    /// The menu item that already owns this chord, named for a person to read.
    static func reservingMenuItem(for shortcut: CommandShortcut) -> String? {
        for reservation in all {
            guard let reserved = try? CommandShortcut(keystroke: reservation.keystroke) else { continue }
            if reserved == shortcut {
                return SpotiglassL10n.string(reservation.menuTitleKey)
            }
        }
        return nil
    }
}
