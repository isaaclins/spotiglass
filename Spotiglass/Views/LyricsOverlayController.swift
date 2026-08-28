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

    init(
        content: Content,
        isActive: Bool,
        keymapStore: CommandPaletteKeymapStore? = nil
    ) {
        self.content = content
        self.isActive = isActive
        self.keymapStore = keymapStore
    }

    func makeNSView(context: Context) -> LyricsOverlayFocusContainerView<Content> {
        LyricsOverlayFocusContainerView(
            content: content,
            isActive: isActive,
            keymapStore: keymapStore ?? CommandPaletteKeymapStore()
        )
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
    ]
}

/// Owns the keyboard focus while the lyrics overlay is presented and returns it
/// to the responder that was focused before the presentation opened.
@MainActor
final class LyricsOverlayFocusContainerView<Content: View>: NSView, FocusedKeyEventOwner {
    private let hostingView: NSHostingView<Content>
    private let keymapStore: CommandPaletteKeymapStore
    private var overlayIsActive: Bool
    private var capturedPreviousResponder = false
    private weak var previousWindow: NSWindow?
    private var previousResponder: NSResponder?
    private var focusRequestScheduled = false

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

    /// The local monitor has yielded to this focused owner. Do not let AppKit's
    /// default key-view traversal escape the overlay when this container itself
    /// is the first responder.
    override func keyDown(with event: NSEvent) {}

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard ownsKeyEvent(event) else {
            return super.performKeyEquivalent(with: event)
        }
        return true
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
            _ = window.makeFirstResponder(self)
        }
    }

    private func restorePreviousFocus() {
        let window = previousWindow
        let responder = previousResponder
        previousWindow = nil
        previousResponder = nil
        capturedPreviousResponder = false

        guard let window else { return }
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
