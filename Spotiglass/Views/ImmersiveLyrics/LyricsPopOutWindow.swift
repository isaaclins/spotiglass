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
        newWindow.setFrameUsingName(frameAutosaveName)
        newWindow.setFrameAutosaveName(frameAutosaveName)
    }

    /// Pinned, the window floats above other apps' windows and also shows over a full-screen app,
    /// like Picture in Picture. Unpinned, it is an ordinary window again.
    static func apply(isPinned: Bool, to window: NSWindow) {
        window.level = isPinned ? .floating : .normal
        if isPinned {
            window.collectionBehavior.insert(.fullScreenAuxiliary)
        } else {
            window.collectionBehavior.remove(.fullScreenAuxiliary)
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
