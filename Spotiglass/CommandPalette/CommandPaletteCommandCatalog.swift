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
    private static func localizedTitle(commandID: String) -> String {
        SpotiglassL10n.string(String.LocalizationValue("palette.command.\(commandID).title"))
    }

    private static func localizedSubtitle(commandID: String) -> String {
        SpotiglassL10n.string(String.LocalizationValue("palette.command.\(commandID).subtitle"))
    }

    private static func spec(
        commandID: String,
        iconSystemName: String,
        defaultWhen: CommandPaletteContext,
        defaultKeystroke: String?
    ) -> CommandPaletteCommandSpec {
        CommandPaletteCommandSpec(
            commandID: commandID,
            title: localizedTitle(commandID: commandID),
            subtitle: localizedSubtitle(commandID: commandID),
            iconSystemName: iconSystemName,
            defaultWhen: defaultWhen,
            defaultKeystroke: defaultKeystroke
        )
    }

    static let editable: [CommandPaletteCommandSpec] = [
        spec(
            commandID: CommandPaletteCommandID.openSettings,
            iconSystemName: "gearshape",
            defaultWhen: .always,
            defaultKeystroke: "cmd-,"
        ),
        spec(
            commandID: CommandPaletteCommandID.openPalette,
            iconSystemName: "command.circle",
            defaultWhen: .always,
            defaultKeystroke: "cmd-k"
        ),
        spec(
            commandID: CommandPaletteCommandID.refreshPlaylists,
            iconSystemName: "arrow.clockwise",
            defaultWhen: .signedIn,
            defaultKeystroke: "cmd-r"
        ),
        spec(
            commandID: CommandPaletteCommandID.connectPlayback,
            iconSystemName: "dot.radiowaves.left.and.right",
            defaultWhen: .signedIn,
            defaultKeystroke: "shift-cmd-k"
        ),
        spec(
            commandID: CommandPaletteCommandID.togglePlayback,
            iconSystemName: "playpause",
            defaultWhen: .signedIn,
            defaultKeystroke: "space"
        ),
        spec(
            commandID: CommandPaletteCommandID.nextTrack,
            iconSystemName: "forward.fill",
            defaultWhen: .signedIn,
            defaultKeystroke: "shift-cmd-right"
        ),
        spec(
            commandID: CommandPaletteCommandID.previousTrack,
            iconSystemName: "backward.fill",
            defaultWhen: .signedIn,
            defaultKeystroke: "shift-cmd-left"
        ),
        spec(
            commandID: CommandPaletteCommandID.toggleQueue,
            iconSystemName: "list.bullet.indent",
            defaultWhen: .signedIn,
            defaultKeystroke: "alt-cmd-q"
        ),
        spec(
            commandID: CommandPaletteCommandID.toggleLyrics,
            iconSystemName: "music.note.list",
            defaultWhen: .signedIn,
            defaultKeystroke: nil
        ),
        spec(
            commandID: CommandPaletteCommandID.signOut,
            iconSystemName: "xmark.circle",
            defaultWhen: .signedIn,
            defaultKeystroke: nil
        ),
        spec(
            commandID: CommandPaletteCommandID.pinSelected,
            iconSystemName: "pin",
            defaultWhen: .paletteOpen,
            defaultKeystroke: "cmd-return"
        ),
        spec(
            commandID: CommandPaletteCommandID.unpinSelected,
            iconSystemName: "pin.slash",
            defaultWhen: .paletteOpen,
            defaultKeystroke: nil
        ),
        spec(
            commandID: CommandPaletteCommandID.enqueueSelected,
            iconSystemName: "text.line.last.and.arrowtriangle.forward",
            defaultWhen: .paletteOpen,
            defaultKeystroke: "shift-return"
        ),
        spec(
            commandID: CommandPaletteCommandID.prefetchAllPlaylists,
            iconSystemName: "square.and.arrow.down.on.square",
            defaultWhen: .signedIn,
            defaultKeystroke: nil
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
