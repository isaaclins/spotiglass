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
    @ObservedObject var sceneRegistry: SpotiglassSceneRegistry
    @ObservedObject var keymapStore: CommandPaletteKeymapStore
    /// Commands are built outside the window content, so observe the settings
    /// store directly to rebuild the commands tree when the app language changes.
    @ObservedObject var settingsStore: SpotiglassSettingsStore
    /// Which service is on screen: Sign Out and the transport items follow it.
    @ObservedObject var serviceStore: MusicServiceStore

    private var locale: Locale {
        settingsStore.appLocale
    }

    /// Playback, queue, lyrics and refresh only have a target while a Spotify
    /// session is live, so those items dim instead of silently doing nothing.
    let isSignedIn: Bool
    /// Drives the "Show Queue" / "Hide Queue" title, read from the same
    /// `StoredFlag.queuePanelVisible` the browser writes.
    let isQueueVisible: Bool

    /// Every menu item targets the key main window's scene. One active-scene
    /// policy drives the menu, the palette and the lyrics overlay, so a second
    /// window can never be commanded through the first window's menu bar.
    private var activeCommandPaletteManager: CommandPaletteManager? {
        sceneRegistry.activeScene?.commandPaletteManager
    }

    /// Every item acts on a main window. With all of them closed (only the pop-out lyrics window
    /// or Settings open) there is nothing to act on, so the items dim instead of doing nothing (#439).
    var isAvailable: Bool {
        isSignedIn && sceneRegistry.activeScene != nil
    }

    /// Back dims when the active browser's navigation stack is empty.
    private var canNavigateBack: Bool {
        activeCommandPaletteManager?.canNavigateBack ?? false
    }

    /// Whether the active browser selection can be queued at all.
    private var canEnqueueTrackSelection: Bool {
        activeCommandPaletteManager?.canEnqueueTrackSelection ?? false
    }

    /// Whether the active browser selection offers Pin, Unpin, or neither.
    private var trackSelectionPinState: TrackSelectionPinState {
        activeCommandPaletteManager?.trackSelectionPinState ?? .unavailable
    }

    /// Drives the "Show Lyrics" / "Hide Lyrics" title for the active scene.
    private var isLyricsPresented: Bool {
        sceneRegistry.activeScene?.lyricsOverlayController.isPresented ?? false
    }

    /// `false` while the selected service can't play (Apple Music without a subscription):
    /// transport items that only check sign-in would be enabled and do nothing there.
    var hasPlayback = true

    /// Connect Playback (and its ⇧⌘K) is there only for a player that has a connection to make:
    /// Spotify's web player. Apple Music plays on this Mac, so it has none (#453). With no
    /// window open, it follows the selected service.
    var isConnectPlaybackOffered: Bool {
        activeCommandPaletteManager?.canConnectPlayback ?? (serviceStore.active == .spotify)
    }

    /// Next and Previous Track need a song to skip from (#500).
    var isSkipEnabled: Bool {
        isAvailable && hasPlayback && (activeCommandPaletteManager?.canSkipTrack ?? false)
    }

    var isPlaybackToggleEnabled: Bool {
        isAvailable && (activeCommandPaletteManager?.canTogglePlayback ?? false)
    }

    /// Refresh reloads the page you're on; while the lyrics cover it there's nothing to reload (#438).
    var isRefreshEnabled: Bool {
        isAvailable && !isLyricsPresented
    }

    /// Back and the track-selection commands act on the page under the lyrics, which you
    /// can't see while they are open; the toolbar hides Back for the same reason (#438).
    var isBackEnabled: Bool {
        isAvailable && canNavigateBack && !isLyricsPresented
    }

    var isTrackSelectionEnqueueEnabled: Bool {
        isAvailable && hasPlayback && canEnqueueTrackSelection && !isLyricsPresented
    }

    var isTrackSelectionPinEnabled: Bool {
        isAvailable && trackSelectionPinState != .unavailable && !isLyricsPresented
    }

    var isLyricsToggleEnabled: Bool {
        // Hide Lyrics works whenever the lyrics show (#486).
        isAvailable && (isLyricsPresented || (activeCommandPaletteManager?.canToggleLyrics ?? false))
    }

    /// The live transport state is mirrored by the active scene's manager so
    /// SwiftUI can bridge it to an `NSMenuItem` state/checkmark.
    var isShuffleEnabled: Bool {
        activeCommandPaletteManager?.shuffleEnabled ?? false
    }

    var selectedRepeatMode: MusicRepeatMode {
        activeCommandPaletteManager?.repeatMode ?? .off
    }

    var isPlaybackTransportMutationEnabled: Bool {
        isAvailable && (activeCommandPaletteManager?.canMutatePlaybackTransport ?? false)
    }

    /// Repeat follows the music you hear (#396), Shuffle the on-screen queue.
    var isRepeatMutationEnabled: Bool {
        isAvailable && (activeCommandPaletteManager?.canMutateRepeat ?? false)
    }

    var isPrefetchInFlight: Bool {
        activeCommandPaletteManager?.prefetchProgress?.phase == .running
    }

    var prefetchItemTitle: String {
        isPrefetchInFlight
            ? SpotiglassL10n.string("menu.file.stopLoadingSongs")
            : SpotiglassL10n.string("menu.file.loadAllSongs")
    }

    var body: some Commands {
        // Reading the store here is intentional: `CommandMenu` captures its
        // title when the commands tree is resolved, so a menu-local string
        // lookup alone cannot make it follow a later language change.
        let currentLocale = locale

        CommandGroup(after: .appSettings) {
            // Apple Music access is a system permission, not a sign-in this app can undo, and
            // it signs out in Settings › Account instead (#373): no Disconnect here.
            if serviceStore.active == .spotify {
                Button(SpotiglassL10n.string("menu.app.signOut", locale: currentLocale)) {
                    run(CommandPaletteCommandID.signOut)
                }
                .disabled(!isAvailable)
            }
        }

        CommandGroup(after: .importExport) {
            Button(prefetchItemTitle) {
                run(CommandPaletteCommandID.prefetchAllPlaylists)
            }
            .keyboardShortcut(keymapShortcut(for: CommandPaletteCommandID.prefetchAllPlaylists))
            .disabled(!isAvailable)
        }

        CommandGroup(replacing: .sidebar) {
            // Replaces the system Show/Hide Sidebar item, which only had ⌃⌘S and only reached
            // the sidebar while focus sat inside it (#436). This one follows the keymap (⌘S by
            // default) and toggles the browser's own sidebar state, so it works with lyrics or
            // the queue focused too. ⌃⌘S keeps working through the key monitor.
            Button(sidebarItemTitle) {
                // A text field has no use for ⌘S, and the sidebar must not move while typing.
                guard !CommandPaletteSidebarShortcut.isTypingKeyPress(NSApp.currentEvent) else { return }
                // The pop-out lyrics window has no sidebar: the main window comes forward and its
                // sidebar moves, like every other main-window command chosen there (#439).
                if LyricsPopOutWindow.isPopOut(NSApp.keyWindow), let scene = sceneRegistry.activeScene {
                    scene.performMenuCommand(CommandPaletteCommandID.toggleSidebar)
                } else if let manager = activeCommandPaletteManager {
                    manager.execute(commandID: CommandPaletteCommandID.toggleSidebar)
                } else {
                    NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
                }
            }
            .keyboardShortcut(keymapShortcut(for: CommandPaletteCommandID.toggleSidebar))
            .disabled(!isSidebarItemEnabled)

            Divider()

            // ⌘[ is the Mac key equivalent for Back. It is hardcoded rather than
            // read from the keymap because `navigateBack` is menu-bar only and
            // therefore cannot be rebound to shadow it.
            Button(SpotiglassL10n.string("menu.view.back", locale: currentLocale)) {
                run(CommandPaletteCommandID.navigateBack)
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(!isBackEnabled)

            Divider()

            Button(SpotiglassL10n.string("menu.view.search", locale: currentLocale)) {
                run(CommandPaletteCommandID.openSearch)
            }
            .keyboardShortcut(keymapShortcut(for: CommandPaletteCommandID.openSearch))
            .disabled(!isAvailable)

            Button(queueItemTitle) {
                run(CommandPaletteCommandID.toggleQueue)
            }
            .keyboardShortcut(keymapShortcut(for: CommandPaletteCommandID.toggleQueue))
            .disabled(!isAvailable)

            Button(lyricsItemTitle) {
                run(CommandPaletteCommandID.toggleLyrics)
            }
            .keyboardShortcut(keymapShortcut(for: CommandPaletteCommandID.toggleLyrics))
            .disabled(!isLyricsToggleEnabled)

            Button(SpotiglassL10n.string("menu.view.popOutLyrics", locale: currentLocale)) {
                run(CommandPaletteCommandID.popOutLyrics)
            }
            .keyboardShortcut(keymapShortcut(for: CommandPaletteCommandID.popOutLyrics))
            .disabled(!isAvailable)

            Divider()

            Button(SpotiglassL10n.string("menu.view.refresh", locale: currentLocale)) {
                run(CommandPaletteCommandID.refreshPlaylists)
            }
            .keyboardShortcut(keymapShortcut(for: CommandPaletteCommandID.refreshPlaylists))
            .disabled(!isRefreshEnabled)
        }

        CommandMenu(SpotiglassL10n.string("menu.playback.title", locale: currentLocale)) {
            // Play/Pause deliberately carries no key equivalent. Its keymap default
            // is bare Space, and a menu key equivalent is matched before the key
            // reaches the focused view, so putting Space here would swallow every
            // space typed into the palette's search field. `CommandPaletteManager`
            // keeps that binding, where it can skip text input first.
            Button(SpotiglassL10n.string("menu.playback.playPause", locale: currentLocale)) {
                run(CommandPaletteCommandID.togglePlayback)
            }
            .disabled(!isPlaybackToggleEnabled)

            Button(SpotiglassL10n.string("menu.playback.next", locale: currentLocale)) {
                run(CommandPaletteCommandID.nextTrack)
            }
            .keyboardShortcut(keymapShortcut(for: CommandPaletteCommandID.nextTrack))
            .disabled(!isSkipEnabled)

            Button(SpotiglassL10n.string("menu.playback.previous", locale: currentLocale)) {
                run(CommandPaletteCommandID.previousTrack)
            }
            .keyboardShortcut(keymapShortcut(for: CommandPaletteCommandID.previousTrack))
            .disabled(!isSkipEnabled)

            Divider()

            // Shuffle and repeat are menu-only commands: they are not in
            // ``CommandPaletteCommandCatalog/editable``, so no keymap entry can
            // shadow these key equivalents and hardcoding them is safe. Toggle
            // and Picker are intentional here: SwiftUI bridges them to native
            // NSMenuItem state, unlike a hand-rolled checkmark HStack (#327).
            Toggle(SpotiglassL10n.string("menu.playback.shuffle", locale: currentLocale), isOn: shuffleBinding)
                .keyboardShortcut("s", modifiers: [.option, .command])
                .disabled(!isPlaybackTransportMutationEnabled)

            // A single shortcut belongs to the cycling command. Applying it to
            // the Picker gives every native option the same NSMenuItem key
            // equivalent, making ⌥⌘R ambiguous and therefore inert (#347).
            Button(SpotiglassL10n.string("menu.playback.repeat", locale: currentLocale)) {
                run(CommandPaletteCommandID.cycleRepeat)
            }
            .keyboardShortcut("r", modifiers: [.option, .command])
            .disabled(!isRepeatMutationEnabled)

            // Keep this native Picker unshortcutted so its live selection state
            // remains represented by AppKit's menu-item checkmark (#320).
            Picker(SpotiglassL10n.string("menu.playback.repeat", locale: currentLocale), selection: repeatModeBinding) {
                ForEach(MusicRepeatMode.allCases, id: \.self) { mode in
                    Text(repeatModeLabel(for: mode))
                        .tag(mode)
                }
            }
            .pickerStyle(.inline)
            .disabled(!isRepeatMutationEnabled)

            Divider()

            // Add to Queue and Pin existed only in the row context menu, so they
            // were unreachable without a right-click. These act on the table
            // selection, so a keyboard user can select a row and use them (#132).
            Button(SpotiglassL10n.string("browser.addToQueue", locale: currentLocale)) {
                run(CommandPaletteCommandID.enqueueTrackSelection)
            }
            .keyboardShortcut("e", modifiers: [.option, .command])
            .disabled(!isTrackSelectionEnqueueEnabled)

            Button(pinItemTitle) {
                run(CommandPaletteCommandID.pinTrackSelection)
            }
            .keyboardShortcut("p", modifiers: [.option, .command])
            .disabled(!isTrackSelectionPinEnabled)

            Divider()

            // Seeking had no keyboard path at all: the scrubber is drag-only and
            // no seek command existed anywhere (#126).
            Button(SpotiglassL10n.string("menu.playback.seekForward", locale: currentLocale)) {
                run(CommandPaletteCommandID.seekForward)
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(!isAvailable || !hasPlayback)

            Button(SpotiglassL10n.string("menu.playback.seekBackward", locale: currentLocale)) {
                run(CommandPaletteCommandID.seekBackward)
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(!isAvailable || !hasPlayback)

            if isConnectPlaybackOffered {
                Divider()

                Button(SpotiglassL10n.string("menu.playback.connect", locale: currentLocale)) {
                    run(CommandPaletteCommandID.connectPlayback)
                }
                .keyboardShortcut(keymapShortcut(for: CommandPaletteCommandID.connectPlayback))
                .disabled(!isAvailable || !hasPlayback)
            }
        }

        // The default Help menu ships an item that leads nowhere: the bundle
        // declares no CFBundleHelpBookName, so choosing it does nothing at all,
        // not even the "help isn't available" sheet the name implies.
        //
        // The "Send Spotiglass Feedback to Apple" item above these is inserted
        // by the system, not by this app, and replacing the group does not
        // remove it. It is present in Safari, TextEdit and Finder on this OS
        // too, so it is not ours to take out. The shape that leaves is the one
        // Safari has: feedback, the app's own help, then an extra item (#177).
        CommandGroup(replacing: .help) {
            Button(SpotiglassL10n.string("menu.help.spotiglassHelp", locale: currentLocale)) {
                Self.open(Self.readmeURL)
            }
            .keyboardShortcut("?", modifiers: .command)

            Divider()

            Button(SpotiglassL10n.string("menu.help.reportIssue", locale: currentLocale)) {
                Self.open(Self.newIssueURL)
            }
        }
    }

    /// The README is the only real documentation this project has, so it is what
    /// Help points at rather than a help book that does not exist.
    static let readmeURL = URL(string: "https://github.com/isaaclins/spotiglass#readme")!
    static let newIssueURL = URL(string: "https://github.com/isaaclins/spotiglass/issues/new")!

    private static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// With another window in front (Settings) the item is that window's, so its title can't
    /// name the browser's sidebar state, and it works signed out too, as the system item did.
    var sidebarItemTitle: String {
        guard sceneRegistry.isMainWindowInFront else {
            return SpotiglassL10n.string("palette.command.view.sidebar.toggle.title", locale: locale)
        }
        return (activeCommandPaletteManager?.isSidebarVisible ?? true)
            ? SpotiglassL10n.string("menu.view.hideSidebar", locale: locale)
            : SpotiglassL10n.string("menu.view.showSidebar", locale: locale)
    }

    var isSidebarItemEnabled: Bool {
        isSidebarItemEnabled(keyWindow: NSApp.keyWindow)
    }

    /// With the pop-out lyrics window in front the item acts on a main window, so it needs one
    /// (#439); otherwise it is the window in front's own sidebar, Settings' included (#436).
    func isSidebarItemEnabled(keyWindow: NSWindow?) -> Bool {
        if LyricsPopOutWindow.isPopOut(keyWindow) { return isAvailable }
        return isSignedIn || !sceneRegistry.isMainWindowInFront
    }

    private var queueItemTitle: String {
        isQueueVisible
            ? SpotiglassL10n.string("menu.view.hideQueue", locale: locale)
            : SpotiglassL10n.string("menu.view.showQueue", locale: locale)
    }

    /// Unpin only when every selected row is already pinned, matching what the
    /// command actually does.
    private var pinItemTitle: String {
        trackSelectionPinState == .unpin
            ? SpotiglassL10n.string("browser.unpin", locale: locale)
            : SpotiglassL10n.string("browser.pin", locale: locale)
    }

    var lyricsItemTitle: String {
        isLyricsPresented
            ? SpotiglassL10n.string("menu.view.hideLyrics", locale: locale)
            : SpotiglassL10n.string("menu.view.showLyrics", locale: locale)
    }

    private var shuffleBinding: Binding<Bool> {
        Binding(
            get: { isShuffleEnabled },
            set: { [weak manager = activeCommandPaletteManager] newValue in
                guard let manager, manager.shuffleEnabled != newValue else { return }
                manager.execute(commandID: CommandPaletteCommandID.toggleShuffle)
            }
        )
    }

    private var repeatModeBinding: Binding<MusicRepeatMode> {
        Binding(
            get: { selectedRepeatMode },
            set: { [weak manager = activeCommandPaletteManager] newMode in
                guard let manager, manager.repeatMode != newMode else { return }
                manager.requestRepeatMode(newMode)
            }
        )
    }

    private func repeatModeLabel(for mode: MusicRepeatMode) -> String {
        switch mode {
        case .off:
            SpotiglassL10n.string("playback.repeat.off", locale: locale)
        case .context:
            SpotiglassL10n.string("playback.repeat.playlist", locale: locale)
        case .track:
            SpotiglassL10n.string("playback.repeat.one", locale: locale)
        }
    }

    private func run(_ commandID: String) {
        sceneRegistry.activeScene?.performMenuCommand(commandID)
    }

    private func keymapShortcut(for commandID: String) -> KeyboardShortcut? {
        keymapStore.menuShortcut(for: commandID)
    }
}
