import AppKit
import SwiftUI

/// Gives the `Settings` scene the same unified titlebar as the main window (#19).
///
/// The main window is a `WindowGroup` whose content declares a real SwiftUI
/// `.toolbar`, so AppKit installs an `NSToolbar` and lays the window out with
/// the taller unified titlebar: its traffic lights sit at an 18 pt inset.
/// SwiftUI's `Settings` scene never installs an `NSToolbar` (it renders
/// declared toolbar content inline in the window body instead), so its window
/// keeps the short standard titlebar with the lights at an 8 pt inset. Scene
/// modifiers such as `.windowToolbarStyle(.unified)` cannot close that gap,
/// because they only style a toolbar that is never created.
///
/// Attaching an empty `NSToolbar` to the backing window restores the unified
/// metrics, which is also what Apple's own System Settings window uses. This
/// only calls public AppKit API on the window SwiftUI already created.
struct SettingsWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { UnifiedTitlebarProbeView() }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Zero-sized helper view whose only job is to reach the hosting `NSWindow`
/// once SwiftUI has attached it, and to give its titlebar the unified layout.
final class UnifiedTitlebarProbeView: NSView {
    static let toolbarIdentifier = NSToolbar.Identifier("SpotiglassSettingsTitlebar")

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // Deferred on purpose: SwiftUI's settings window controller is still in
        // its first constraint pass here, and swapping the titlebar mid-pass
        // makes it raise an NSRangeException.
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            Self.applyUnifiedTitlebar(to: window)
        }
    }

    /// An empty, non-customizable toolbar is enough: AppKit only needs a
    /// toolbar to be present to lay the window out with the taller titlebar.
    /// Idempotent, so reopening the settings window keeps one toolbar.
    static func applyUnifiedTitlebar(to window: NSWindow) {
        if window.toolbar == nil {
            let toolbar = NSToolbar(identifier: toolbarIdentifier)
            toolbar.allowsUserCustomization = false
            window.toolbar = toolbar
        }
        window.toolbarStyle = .unified
    }
}
