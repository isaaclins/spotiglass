import Foundation

/// Single source of truth for command palette commands that appear in the palette and in Settings → Keyboard.
struct CommandPaletteCommandSpec: Identifiable {
    var id: String { commandID }

    let commandID: String
    let title: String
    let subtitle: String
    let iconSystemName: String
    /// Context filter stored in `keymap.json` for this command’s default binding.
    let defaultWhen: CommandPaletteContext
    /// When non-`nil`, included in the default keymap JSON.
    let defaultKeystroke: String?

    /// Commands that only make sense while signed in (still listed in Keyboard settings when signed out).
    var requiresSignInForPalette: Bool {
        defaultWhen == .signedIn
    }
}

enum CommandPaletteCommandCatalog {
    static let editable: [CommandPaletteCommandSpec] = [
        CommandPaletteCommandSpec(
            commandID: CommandPaletteCommandID.openSettings,
            title: "Open Settings",
            subtitle: "Spotiglass preferences and shortcuts",
            iconSystemName: "gearshape",
            defaultWhen: .always,
            defaultKeystroke: "cmd-,"
        ),
        CommandPaletteCommandSpec(
            commandID: CommandPaletteCommandID.openPalette,
            title: "Open Command Palette",
            subtitle: "Search tracks, playlists, and commands",
            iconSystemName: "command.circle",
            defaultWhen: .always,
            defaultKeystroke: "cmd-k"
        ),
        CommandPaletteCommandSpec(
            commandID: CommandPaletteCommandID.refreshPlaylists,
            title: "Refresh",
            subtitle: "Reload the focused library, playlist, artist, or queue",
            iconSystemName: "arrow.clockwise",
            defaultWhen: .signedIn,
            defaultKeystroke: "cmd-r"
        ),
        CommandPaletteCommandSpec(
            commandID: CommandPaletteCommandID.connectPlayback,
            title: "Connect Playback",
            subtitle: "Connect Spotiglass playback device",
            iconSystemName: "dot.radiowaves.left.and.right",
            defaultWhen: .signedIn,
            defaultKeystroke: "shift-cmd-k"
        ),
        CommandPaletteCommandSpec(
            commandID: CommandPaletteCommandID.togglePlayback,
            title: "Toggle Play/Pause",
            subtitle: "Pause or resume Spotify playback",
            iconSystemName: "playpause",
            defaultWhen: .signedIn,
            defaultKeystroke: "space"
        ),
        CommandPaletteCommandSpec(
            commandID: CommandPaletteCommandID.nextTrack,
            title: "Next Track",
            subtitle: "Skip to the next track",
            iconSystemName: "forward.fill",
            defaultWhen: .signedIn,
            defaultKeystroke: "shift-cmd-right"
        ),
        CommandPaletteCommandSpec(
            commandID: CommandPaletteCommandID.previousTrack,
            title: "Previous Track",
            subtitle: "Return to the previous track",
            iconSystemName: "backward.fill",
            defaultWhen: .signedIn,
            defaultKeystroke: "shift-cmd-left"
        ),
        CommandPaletteCommandSpec(
            commandID: CommandPaletteCommandID.toggleQueue,
            title: "Toggle Queue",
            subtitle: "Show or hide the playback queue panel",
            iconSystemName: "list.bullet.indent",
            defaultWhen: .signedIn,
            defaultKeystroke: "alt-cmd-q"
        ),
        CommandPaletteCommandSpec(
            commandID: CommandPaletteCommandID.toggleLyrics,
            title: "Toggle Lyrics",
            subtitle: "Show or hide immersive synchronized lyrics",
            iconSystemName: "music.note.list",
            defaultWhen: .signedIn,
            defaultKeystroke: nil
        ),
        CommandPaletteCommandSpec(
            commandID: CommandPaletteCommandID.signOut,
            title: "Disconnect Spotify",
            subtitle: "Sign out and clear local session",
            iconSystemName: "xmark.circle",
            defaultWhen: .signedIn,
            defaultKeystroke: nil
        ),
        CommandPaletteCommandSpec(
            commandID: CommandPaletteCommandID.pinSelected,
            title: "Pin Selected Palette Item",
            subtitle: "Pin the highlighted result to the sidebar",
            iconSystemName: "pin",
            defaultWhen: .paletteOpen,
            defaultKeystroke: "cmd-return"
        ),
        CommandPaletteCommandSpec(
            commandID: CommandPaletteCommandID.unpinSelected,
            title: "Unpin Selected Palette Item",
            subtitle: "Remove the highlighted result from the sidebar",
            iconSystemName: "pin.slash",
            defaultWhen: .paletteOpen,
            defaultKeystroke: nil
        ),
        CommandPaletteCommandSpec(
            commandID: CommandPaletteCommandID.enqueueSelected,
            title: "Add Selected Palette Item to Queue",
            subtitle: "Queues the highlighted track without dismissing the palette",
            iconSystemName: "text.line.last.and.arrowtriangle.forward",
            defaultWhen: .paletteOpen,
            defaultKeystroke: "shift-return"
        ),
    ]

    /// Stable on-disk order for default `keymap.json` (matches historical Spotiglass defaults).
    private static let defaultKeymapFileOrder: [String] = [
        CommandPaletteCommandID.openPalette,
        CommandPaletteCommandID.refreshPlaylists,
        CommandPaletteCommandID.connectPlayback,
        CommandPaletteCommandID.togglePlayback,
        CommandPaletteCommandID.nextTrack,
        CommandPaletteCommandID.previousTrack,
        CommandPaletteCommandID.toggleQueue,
        CommandPaletteCommandID.openSettings,
        CommandPaletteCommandID.pinSelected,
        CommandPaletteCommandID.enqueueSelected,
    ]

    /// Canonical default keymap JSON (matches `CommandPaletteKeymapStore` bootstrap).
    static var defaultKeymapJSON: String {
        var lines: [String] = ["{", "  \"bindings\": ["]
        var entries: [String] = []
        for commandID in defaultKeymapFileOrder {
            guard let spec = editable.first(where: { $0.commandID == commandID }),
                  let ks = spec.defaultKeystroke
            else { continue }
            let whenRaw = spec.defaultWhen.rawValue
            entries.append("    { \"keystrokes\": [\"\(ks)\"], \"command\": \"\(spec.commandID)\", \"when\": \"\(whenRaw)\" }")
        }
        lines.append(entries.joined(separator: ",\n"))
        lines.append("  ]")
        lines.append("}")
        return lines.joined(separator: "\n")
    }
}
