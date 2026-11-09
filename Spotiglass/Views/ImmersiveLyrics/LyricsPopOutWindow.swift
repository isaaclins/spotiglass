import AppKit
import SwiftUI

/// The small lyrics window that pops out of the lyrics view and can stay above every other app
/// (#439). It is one SwiftUI `Window` scene, so opening it again brings the same window forward
/// instead of making a second one, and closing it only closes the window: playback is app-scoped.
@MainActor
enum LyricsPopOutWindow {
    static let sceneID = "lyrics-popout"
    /// Size and position are remembered under this name, the way AppKit remembers any window.
    static let frameAutosaveName = "Spotiglass Lyrics Pop-Out"
    /// The unit tests run inside the app and AppKit saves frames in the app's real preferences,
    /// so test windows never save or restore one: they can't move or resize the real pop-out.
    static let savesFrame = !AppMetadata.isRunningUnitTests
    /// Whether the window stays above other apps. On by default: that is what it is for.
    static let pinnedStorageKey = "lyrics.popOut.pinned"
    static let isPinnedByDefault = true
    static let defaultSize = CGSize(
        width: SpotiglassDesign.Layout.lyricsPopOutDefaultWidth,
        height: SpotiglassDesign.Layout.lyricsPopOutDefaultHeight
    )
    /// Small enough for a one-line strip under a menu bar or along a screen edge.
    static let minimumSize = CGSize(
        width: SpotiglassDesign.Layout.lyricsPopOutMinWidth,
        height: SpotiglassDesign.Layout.lyricsPopOutMinHeight
    )

    /// The live pop-out window, so key handling can tell it apart from the main windows.
    private static weak var window: NSWindow?

    static func isPopOut(_ candidate: NSWindow?) -> Bool {
        guard let candidate, let window else { return false }
        return candidate === window
    }

    /// Called once the content is in its window: names it for frame saving and restores the
    /// saved frame before it first shows.
    static func adopt(_ newWindow: NSWindow) {
        guard window !== newWindow else { return }
        window = newWindow
        newWindow.isMovableByWindowBackground = true
        guard savesFrame else { return }
        newWindow.setFrameUsingName(frameAutosaveName)
        newWindow.setFrameAutosaveName(frameAutosaveName)
    }

    /// Menu commands that act right where you are when the pop-out has focus: they control the
    /// music it shows. Every other menu command belongs to a main window, so that window comes
    /// forward first instead of changing out of sight behind the pop-out.
    static let commandIDsRunInPlace: Set<String> = [
        CommandPaletteCommandID.togglePlayback,
        CommandPaletteCommandID.nextTrack,
        CommandPaletteCommandID.previousTrack,
        CommandPaletteCommandID.cycleRepeat,
        CommandPaletteCommandID.seekForward,
        CommandPaletteCommandID.seekBackward,
        CommandPaletteCommandID.popOutLyrics,
    ]

    /// Popping out from a main window moves the lyrics: that window's lyrics view closes. Asked
    /// for again while the pop-out itself is in front, it only brings the pop-out forward and
    /// leaves the lyrics view in the window behind it alone.
    static func popOutClosesLyricsView(keyWindow: NSWindow?) -> Bool {
        !isPopOut(keyWindow)
    }

    /// Whether a menu command chosen while the pop-out has focus first needs a main window in front.
    static func bringsMainWindowForward(for commandID: String, keyWindow: NSWindow?) -> Bool {
        isPopOut(keyWindow) && !commandIDsRunInPlace.contains(commandID)
    }

    /// The keys the pop-out answers itself (Play/Pause, Next, Previous, as bound in Settings ›
    /// Keyboard). It needs no main window for them: they work with every main window closed.
    static let keyCommandIDs: Set<String> = [
        CommandPaletteCommandID.togglePlayback,
        CommandPaletteCommandID.nextTrack,
        CommandPaletteCommandID.previousTrack,
    ]

    /// Pinned, the window floats above other apps' windows. It can also sit over Spotiglass's own
    /// full-screen window. It does not follow you onto another app's full-screen Space: tried with
    /// `.canJoinAllSpaces` too, a regular app window stays on its own desktop. Unpinned, it is an
    /// ordinary window again.
    static let pinnedCollectionBehavior: NSWindow.CollectionBehavior = [.fullScreenAuxiliary]

    static func apply(isPinned: Bool, to window: NSWindow) {
        window.level = isPinned ? .floating : .normal
        if isPinned {
            window.collectionBehavior.insert(pinnedCollectionBehavior)
        } else {
            window.collectionBehavior.remove(pinnedCollectionBehavior)
        }
    }
}

/// How the pop-out arranges itself for its current size.
enum LyricsPopOutLayout: Equatable {
    /// Short window: one row with the artwork, the line being sung and the controls.
    case strip
    /// Artwork, title and controls on top, the scrolling synced lyrics below.
    case full

    /// Below this height there is no room for more than one lyric line.
    static let stripMaxHeight = SpotiglassDesign.Layout.lyricsPopOutStripMaxHeight
    /// Below this width only Play/Pause and the pin stay next to the title.
    static let skipButtonsMinWidth = SpotiglassDesign.Layout.lyricsPopOutSkipButtonsMinWidth

    static func layout(for size: CGSize) -> LyricsPopOutLayout {
        size.height < stripMaxHeight ? .strip : .full
    }

    static func showsSkipButtons(width: CGFloat) -> Bool {
        width >= skipButtonsMinWidth
    }
}

/// Hands the hosting `NSWindow` to ``LyricsPopOutWindow`` and keeps its level in step with the pin.
struct LyricsPopOutWindowConfigurator: NSViewRepresentable {
    let isPinned: Bool

    func makeNSView(context: Context) -> ProbeView {
        ProbeView(isPinned: isPinned)
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.isPinned = isPinned
    }

    final class ProbeView: NSView {
        var isPinned: Bool {
            didSet { applyToWindow() }
        }

        init(isPinned: Bool) {
            self.isPinned = isPinned
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            LyricsPopOutWindow.adopt(window)
            applyToWindow()
        }

        private func applyToWindow() {
            guard let window else { return }
            LyricsPopOutWindow.apply(isPinned: isPinned, to: window)
        }
    }
}

/// What the pop-out's Previous, Play/Pause and Next do and when they can, for its buttons and its
/// keys alike: the same rules as the player bar's.
@MainActor
enum LyricsPopOutTransport {
    static func canRun(_ commandID: String, on player: PlaybackSessionViewModel) -> Bool {
        switch commandID {
        case CommandPaletteCommandID.togglePlayback:
            player.isPlaybackToggleReady
        case CommandPaletteCommandID.previousTrack:
            player.connectionState.hasReadyDevice && !player.isSkipCommandPending
        case CommandPaletteCommandID.nextTrack:
            player.connectionState.hasReadyDevice
                && !player.isSkipCommandPending
                && !player.isNextCommandLockedOut
        default:
            false
        }
    }

    static func run(_ commandID: String, on player: PlaybackSessionViewModel) {
        guard canRun(commandID, on: player) else { return }
        switch commandID {
        case CommandPaletteCommandID.togglePlayback:
            Task { await player.togglePlayPause() }
        case CommandPaletteCommandID.previousTrack:
            Task { await player.previous() }
        case CommandPaletteCommandID.nextTrack:
            Task { await player.next() }
        default:
            break
        }
    }

    /// The pop-out command a key press in the pop-out stands for, if any.
    static func commandID(for event: NSEvent, keymapStore: CommandPaletteKeymapStore) -> String? {
        guard event.type == .keyDown, !event.isARepeat, LyricsPopOutWindow.isPopOut(event.window) else { return nil }
        return keymapStore.commandBindings(for: event, context: .signedIn)
            .map(\.command)
            .first(where: LyricsPopOutWindow.keyCommandIDs.contains)
    }
}

/// Answers the pop-out's own transport keys. Main windows' key handling leaves the pop-out alone,
/// so these keys keep working when every main window is closed.
struct LyricsPopOutKeyMonitor: NSViewRepresentable {
    let keymapStore: CommandPaletteKeymapStore
    let player: PlaybackSessionViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(keymapStore: keymapStore, player: player)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.start()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.keymapStore = keymapStore
        context.coordinator.player = player
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        var keymapStore: CommandPaletteKeymapStore
        var player: PlaybackSessionViewModel
        private var monitor: Any?

        init(keymapStore: CommandPaletteKeymapStore, player: PlaybackSessionViewModel) {
            self.keymapStore = keymapStore
            self.player = player
        }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return MainActor.assumeIsolated { self.handle(event) } ? nil : event
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        /// True when the key was the pop-out's and it acted on it.
        func handle(_ event: NSEvent) -> Bool {
            guard let commandID = LyricsPopOutTransport.commandID(for: event, keymapStore: keymapStore),
                  LyricsPopOutTransport.canRun(commandID, on: player)
            else { return false }
            LyricsPopOutTransport.run(commandID, on: player)
            return true
        }
    }
}
