import AppKit
import Combine
import SwiftUI

/// Hosts the lyrics surface in an AppKit responder parent. This keeps the overlay
/// owner in the focused responder's chain even when a SwiftUI child button or
/// scroll view takes keyboard focus.
struct LyricsOverlayFocusContainer<Content: View>: NSViewRepresentable {
    let content: Content
    let isActive: Bool
    let keymapStore: CommandPaletteKeymapStore?
    let keyboardFocus: LyricsKeyboardFocusProbe?

    init(
        content: Content,
        isActive: Bool,
        keymapStore: CommandPaletteKeymapStore? = nil,
        keyboardFocus: LyricsKeyboardFocusProbe? = nil
    ) {
        self.content = content
        self.isActive = isActive
        self.keymapStore = keymapStore
        self.keyboardFocus = keyboardFocus
    }

    func makeNSView(context: Context) -> LyricsOverlayFocusContainerView<Content> {
        let view = LyricsOverlayFocusContainerView(
            content: content,
            isActive: isActive,
            keymapStore: keymapStore ?? CommandPaletteKeymapStore()
        )
        keyboardFocus?.container = view
        return view
    }

    func updateNSView(_ nsView: LyricsOverlayFocusContainerView<Content>, context: Context) {
        nsView.updateContent(content)
        nsView.setActive(isActive)
    }

    static func dismantleNSView(
        _ nsView: LyricsOverlayFocusContainerView<Content>,
        coordinator: Coordinator
    ) {
        nsView.deactivate()
    }
}

private enum LyricsOverlayGlobalCommands {
    static let commandIDs: Set<String> = [
        CommandPaletteCommandID.toggleLyrics,
        CommandPaletteCommandID.togglePlayback,
        CommandPaletteCommandID.nextTrack,
        CommandPaletteCommandID.previousTrack,
        CommandPaletteCommandID.toggleQueue,
        CommandPaletteCommandID.openPalette,
        CommandPaletteCommandID.openSettings,
        // Switching service is app-wide (`.always`) and clears the lyrics on its way (#399).
        CommandPaletteCommandID.switchToAppleMusic,
        CommandPaletteCommandID.switchToSpotify,
    ]
}

/// Tells the lyrics whether the user moved the keyboard out of them, so focus placed once the
/// lyrics finish loading doesn't pull it back from the sidebar or the queue (#438).
@MainActor
final class LyricsKeyboardFocusProbe {
    weak var container: (any LyricsKeyboardFocusOwner)?

    var userMovedFocusAway: Bool {
        container?.keyboardFocusMovedAway ?? false
    }
}

@MainActor
protocol LyricsKeyboardFocusOwner: AnyObject {
    var keyboardFocusMovedAway: Bool { get }
}

private struct LyricsKeyboardFocusKey: EnvironmentKey {
    static var defaultValue: LyricsKeyboardFocusProbe? { nil }
}

extension EnvironmentValues {
    var lyricsKeyboardFocus: LyricsKeyboardFocusProbe? {
        get { self[LyricsKeyboardFocusKey.self] }
        set { self[LyricsKeyboardFocusKey.self] = newValue }
    }
}

/// Owns the keyboard focus while the lyrics overlay is presented and returns it
/// to the responder that was focused before the presentation opened.
@MainActor
final class LyricsOverlayFocusContainerView<Content: View>: NSView, FocusedKeyEventOwner, LyricsKeyboardFocusOwner {
    private let hostingView: NSHostingView<Content>
    private let keymapStore: CommandPaletteKeymapStore
    private var overlayIsActive: Bool
    private var capturedPreviousResponder = false
    private weak var previousWindow: NSWindow?
    private var previousResponder: NSResponder?
    private var focusRequestScheduled = false
    /// Set once the keyboard is in the lyrics, so a later move elsewhere reads as the user's.
    private var didHoldKeyboardFocus = false

    init(content: Content, isActive: Bool, keymapStore: CommandPaletteKeymapStore) {
        hostingView = NSHostingView(rootView: content)
        self.keymapStore = keymapStore
        overlayIsActive = isActive
        super.init(frame: .zero)

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    convenience init(content: Content, isActive: Bool) {
        self.init(
            content: content,
            isActive: isActive,
            keymapStore: CommandPaletteKeymapStore()
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    func updateContent(_ content: Content) {
        hostingView.rootView = content
    }

    func setActive(_ active: Bool) {
        guard overlayIsActive != active else { return }
        overlayIsActive = active
        if active {
            capturePreviousResponderIfNeeded()
            requestFocusIfNeeded()
        } else {
            restorePreviousFocus()
        }
    }

    func deactivate() {
        guard overlayIsActive || capturedPreviousResponder else { return }
        overlayIsActive = false
        restorePreviousFocus()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard overlayIsActive else { return }
        capturePreviousResponderIfNeeded()
        requestFocusIfNeeded()
    }

    override func removeFromSuperview() {
        deactivate()
        super.removeFromSuperview()
    }

    /// Escape remains available to ``CommandPaletteManager``'s existing lyrics
    /// dismissal hook. Transport and global commands also stay with the app-wide
    /// keymap; only events with no matching command remain in the overlay chain.
    func ownsKeyEvent(_ event: NSEvent) -> Bool {
        guard overlayIsActive, event.keyCode != 53 else { return false }
        return !matchesGlobalCommandBinding(event)
    }

    /// The local monitor has yielded to this focused owner, so other keys stop here. Tab and
    /// Shift-Tab move on to the sidebar, the queue and the player bar, which stay usable next
    /// to the lyrics (#438); without a lyrics list (loading, instrumental, no lyrics) this
    /// container is all that has the keyboard.
    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 48, let window else { return }
        if event.modifierFlags.contains(.shift) {
            window.selectPreviousKeyView(self)
        } else {
            window.selectNextKeyView(self)
        }
    }

    /// AppKit offers key equivalents to every view in the window, not only the focused one,
    /// and before the menu bar. The lyrics only claim plain keys, and only while the keyboard
    /// is in them: with focus in the sidebar or the queue, shortcuts work as on every other
    /// screen, and ⌘ shortcuts always reach the menu bar, so Repeat (⌥⌘R, now only in the
    /// player bar), Shuffle and seeking work with the lyrics open (#438). Menu commands that
    /// act on the page under the lyrics are dimmed while they are open.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard hasKeyboardFocus,
            !event.modifierFlags.contains(.command),
            ownsKeyEvent(event)
        else {
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    /// Whether the keyboard is in the lyrics: this container or a view inside it.
    var hasKeyboardFocus: Bool {
        guard let window else { return false }
        return isInResponderChain(window.firstResponder)
    }

    var keyboardFocusMovedAway: Bool {
        if hasKeyboardFocus { didHoldKeyboardFocus = true }
        return didHoldKeyboardFocus && !hasKeyboardFocus
    }

    private func matchesGlobalCommandBinding(_ event: NSEvent) -> Bool {
        keymapStore
            .commandBindings(for: event, context: .signedIn)
            .contains { LyricsOverlayGlobalCommands.commandIDs.contains($0.command) }
    }

    private func capturePreviousResponderIfNeeded() {
        guard !capturedPreviousResponder, let window else { return }
        capturedPreviousResponder = true
        previousWindow = window
        guard let responder = window.firstResponder, !isInResponderChain(responder) else { return }
        previousResponder = responder
    }

    private func requestFocusIfNeeded() {
        guard overlayIsActive,
            let window,
            !isInResponderChain(window.firstResponder),
            !focusRequestScheduled
        else { return }

        // Prefer an immediate handoff when the overlay is inserted during a
        // key-window update. SwiftUI can otherwise leave the old responder in
        // place until the next run-loop turn.
        if window.makeFirstResponder(self) {
            didHoldKeyboardFocus = true
            return
        }

        focusRequestScheduled = true
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self else { return }
            self.focusRequestScheduled = false
            guard self.overlayIsActive,
                let window,
                self.window === window,
                !self.isInResponderChain(window.firstResponder)
            else { return }
            if window.makeFirstResponder(self) { self.didHoldKeyboardFocus = true }
        }
    }

    private func restorePreviousFocus() {
        let window = previousWindow
        let responder = previousResponder
        previousWindow = nil
        previousResponder = nil
        capturedPreviousResponder = false
        didHoldKeyboardFocus = false

        guard let window else { return }
        // The sidebar, the queue and the player bar stay usable next to the lyrics (#438). When
        // the keyboard already moved there (a click on a sidebar row that also closed the
        // lyrics, Escape from the queue), it stays where the user put it.
        if let current = window.firstResponder, current !== window, !isInResponderChain(current) {
            return
        }
        if let responder, responder !== self, isResponderInWindow(responder, window) {
            _ = window.makeFirstResponder(responder)
        } else {
            _ = window.makeFirstResponder(nil)
        }
    }

    private func isResponderInWindow(_ responder: NSResponder, _ window: NSWindow) -> Bool {
        if let view = responder as? NSView {
            return view.window === window
        }
        var current: NSResponder? = responder
        var visited = Set<ObjectIdentifier>()
        while let candidate = current {
            guard visited.insert(ObjectIdentifier(candidate)).inserted else { break }
            if candidate === window { return true }
            current = candidate.nextResponder
        }
        return false
    }

    private func isInResponderChain(_ responder: NSResponder?) -> Bool {
        var current = responder
        var visited = Set<ObjectIdentifier>()
        while let candidate = current {
            guard visited.insert(ObjectIdentifier(candidate)).inserted else { break }
            if candidate === self { return true }
            current = candidate.nextResponder
        }
        return false
    }
}

/// Owns immersive lyrics presentation and holds references to the main-window playback session
/// so ``ImmersiveLyricsView`` can be hosted above ``NavigationSplitView`` (full-window compositing).
@MainActor
final class LyricsOverlayController: ObservableObject {
    @Published var isPresented = false

    private(set) var playbackViewModel: PlaybackSessionViewModel?
    private(set) var queueViewModel: QueueViewModel?
    private(set) var lyricsModel: ImmersiveLyricsViewModel?
    private(set) var navigateToArtist: ((ArtistTapTarget) -> Void)?
    private(set) var navigateToAlbum: ((AlbumTapTarget, String, URL?) -> Void)?

    func attach(
        playback: PlaybackSessionViewModel,
        queue: QueueViewModel,
        lyrics: ImmersiveLyricsViewModel,
        navigateToArtist: @escaping (ArtistTapTarget) -> Void,
        navigateToAlbum: @escaping (AlbumTapTarget, String, URL?) -> Void
    ) {
        playbackViewModel = playback
        queueViewModel = queue
        lyricsModel = lyrics
        self.navigateToArtist = navigateToArtist
        self.navigateToAlbum = navigateToAlbum
    }

    func detach() {
        isPresented = false
        playbackViewModel = nil
        queueViewModel = nil
        lyricsModel = nil
        navigateToArtist = nil
        navigateToAlbum = nil
    }

    func dismiss() {
        isPresented = false
    }
}

/// Renders ``ImmersiveLyricsView`` in the browser's main column, in place of the page that was
/// showing. The sidebar, the queue panel and the player bar stay where they are on every other
/// screen (#438); the backdrop runs up under the toolbar so the bar reads as part of the lyrics.
struct LyricsOverlayLayer: View {
    @ObservedObject var lyricsOverlay: LyricsOverlayController
    let keymapStore: CommandPaletteKeymapStore
    @EnvironmentObject private var settingsStore: SpotiglassSettingsStore
    @State private var keyboardFocus = LyricsKeyboardFocusProbe()

    /// Avoid blocking the column when `isPresented` is true before the browser has called `attach` (nil models).
    private var immersiveLyricsReady: Bool {
        lyricsOverlay.isPresented
            && lyricsOverlay.playbackViewModel != nil
            && lyricsOverlay.queueViewModel != nil
            && lyricsOverlay.lyricsModel != nil
            && lyricsOverlay.navigateToArtist != nil
            && lyricsOverlay.navigateToAlbum != nil
    }

    var body: some View {
        ZStack {
            if immersiveLyricsReady,
                let playback = lyricsOverlay.playbackViewModel,
                let queue = lyricsOverlay.queueViewModel,
                let lyrics = lyricsOverlay.lyricsModel,
                let navigateArtist = lyricsOverlay.navigateToArtist,
                let navigateAlbum = lyricsOverlay.navigateToAlbum
            {
                LyricsOverlayFocusContainer(
                    content: ImmersiveLyricsView(
                        playbackViewModel: playback,
                        queueViewModel: queue,
                        lyricsModel: lyrics,
                        navigateToArtist: navigateArtist,
                        navigateToAlbum: navigateAlbum,
                        onDismiss: { lyricsOverlay.dismiss() }
                    )
                    .environmentObject(settingsStore)
                    .environment(\.locale, settingsStore.appLocale)
                    .environment(\.spotiglassLocale, settingsStore.appLocale)
                    .environment(\.lyricsKeyboardFocus, keyboardFocus),
                    isActive: immersiveLyricsReady,
                    keymapStore: keymapStore,
                    keyboardFocus: keyboardFocus
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.easeOut(duration: 0.22), value: lyricsOverlay.isPresented)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The lines scroll unclipped for the edge fade; in a short window they would draw over
        // the player bar right below the column (#438).
        .clipped()
        .ignoresSafeArea(.container, edges: .top)
        .allowsHitTesting(immersiveLyricsReady)
    }
}
