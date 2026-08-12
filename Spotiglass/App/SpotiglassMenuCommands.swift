import AppKit
import SwiftUI

/// Menu bar surface for the actions Spotiglass already performs, plus the shuffle
/// and repeat controls that until now existed only as buttons inside the queue
/// panel and the transport bar.
///
/// Every item dispatches through ``CommandPaletteManager/execute(commandID:args:)``,
/// so the menu bar, the command palette and the keymap all run one code path. The
/// menu never re-implements a command, it only exposes one.
@MainActor
struct SpotiglassMenuCommands: Commands {
    @ObservedObject var commandPaletteManager: CommandPaletteManager

    /// Playback, queue, lyrics and refresh only have a target while a Spotify
    /// session is live, so those items dim instead of silently doing nothing.
    let isSignedIn: Bool
    /// Drives the "Show Queue" / "Hide Queue" title, read from the same
    /// `queue.panel.visible` app storage the browser writes.
    let isQueueVisible: Bool
    /// Drives the "Show Lyrics" / "Hide Lyrics" title, read from ``LyricsOverlayController``.
    let isLyricsPresented: Bool

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button(SpotiglassL10n.string("menu.app.signOut")) {
                run(CommandPaletteCommandID.signOut)
            }
            .disabled(!isSignedIn)
        }

        CommandGroup(after: .importExport) {
            Button(SpotiglassL10n.string("menu.file.loadAllSongs")) {
                run(CommandPaletteCommandID.prefetchAllPlaylists)
            }
            .keyboardShortcut(keymapShortcut(for: CommandPaletteCommandID.prefetchAllPlaylists))
            .disabled(!isSignedIn)
        }

        CommandGroup(after: .sidebar) {
            Button(SpotiglassL10n.string("menu.view.search")) {
                run(CommandPaletteCommandID.openSearch)
            }
            .keyboardShortcut(keymapShortcut(for: CommandPaletteCommandID.openSearch))
            .disabled(!isSignedIn)

            Button(queueItemTitle) {
                run(CommandPaletteCommandID.toggleQueue)
            }
            .keyboardShortcut(keymapShortcut(for: CommandPaletteCommandID.toggleQueue))
            .disabled(!isSignedIn)

            Button(lyricsItemTitle) {
                run(CommandPaletteCommandID.toggleLyrics)
            }
            .keyboardShortcut(keymapShortcut(for: CommandPaletteCommandID.toggleLyrics))
            .disabled(!isSignedIn)

            Divider()

            Button(SpotiglassL10n.string("menu.view.refresh")) {
                run(CommandPaletteCommandID.refreshPlaylists)
            }
            .keyboardShortcut(keymapShortcut(for: CommandPaletteCommandID.refreshPlaylists))
            .disabled(!isSignedIn)
        }

        CommandMenu(SpotiglassL10n.string("menu.playback.title")) {
            // Play/Pause deliberately carries no key equivalent. Its keymap default
            // is bare Space, and a menu key equivalent is matched before the key
            // reaches the focused view, so putting Space here would swallow every
            // space typed into the palette's search field. `CommandPaletteManager`
            // keeps that binding, where it can skip text input first.
            Button(SpotiglassL10n.string("menu.playback.playPause")) {
                run(CommandPaletteCommandID.togglePlayback)
            }
            .disabled(!isSignedIn)

            Button(SpotiglassL10n.string("menu.playback.next")) {
                run(CommandPaletteCommandID.nextTrack)
            }
            .keyboardShortcut(keymapShortcut(for: CommandPaletteCommandID.nextTrack))
            .disabled(!isSignedIn)

            Button(SpotiglassL10n.string("menu.playback.previous")) {
                run(CommandPaletteCommandID.previousTrack)
            }
            .keyboardShortcut(keymapShortcut(for: CommandPaletteCommandID.previousTrack))
            .disabled(!isSignedIn)

            Divider()

            // Shuffle and repeat are menu-only commands: they are not in
            // ``CommandPaletteCommandCatalog/editable``, so no keymap entry can
            // shadow these key equivalents and hardcoding them is safe.
            Button(SpotiglassL10n.string("menu.playback.shuffle")) {
                run(CommandPaletteCommandID.toggleShuffle)
            }
            .keyboardShortcut("s", modifiers: [.option, .command])
            .disabled(!isSignedIn)

            Button(SpotiglassL10n.string("menu.playback.repeat")) {
                run(CommandPaletteCommandID.cycleRepeat)
            }
            .keyboardShortcut("r", modifiers: [.option, .command])
            .disabled(!isSignedIn)

            Divider()

            Button(SpotiglassL10n.string("menu.playback.connect")) {
                run(CommandPaletteCommandID.connectPlayback)
            }
            .keyboardShortcut(keymapShortcut(for: CommandPaletteCommandID.connectPlayback))
            .disabled(!isSignedIn)
        }
    }

    private var queueItemTitle: String {
        isQueueVisible
            ? SpotiglassL10n.string("menu.view.hideQueue")
            : SpotiglassL10n.string("menu.view.showQueue")
    }

    private var lyricsItemTitle: String {
        isLyricsPresented
            ? SpotiglassL10n.string("menu.view.hideLyrics")
            : SpotiglassL10n.string("menu.view.showLyrics")
    }

    private func run(_ commandID: String) {
        commandPaletteManager.execute(commandID: commandID)
    }

    private func keymapShortcut(for commandID: String) -> KeyboardShortcut? {
        commandPaletteManager.keymapStore.menuShortcut(for: commandID)
    }
}
