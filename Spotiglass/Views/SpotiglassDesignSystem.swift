import AppKit
import SwiftUI

enum SpotiglassDesign {
    /// System accent used by native controls (sliders, progress, focus)—matches System Settings → Accent color.
    static var controlAccent: Color {
        Color(nsColor: .controlAccentColor)
    }

    static let spacingXS: CGFloat = 6
    static let spacingS: CGFloat = 10
    static let spacingM: CGFloat = 16
    static let spacingL: CGFloat = 24
    static let spacingXL: CGFloat = 36

    static let cornerS: CGFloat = 8
    static let cornerM: CGFloat = 14
    static let cornerL: CGFloat = 22

    static let sidebarWidth: CGFloat = 320

    // MARK: - Narrow window (playlist sidebar + queue + detail)

    /// When the window is narrower than this and the queue + playlist sidebar are both visible, min column widths shrink so nothing clips.
    static let tripleColumnCompactBreakpoint: CGFloat = 1080

    static let playlistSidebarMinWidth: CGFloat = 280
    static let playlistSidebarMinWidthCompact: CGFloat = 232

    static let detailColumnMinWidth: CGFloat = 360
    static let detailColumnMinWidthCompact: CGFloat = 272

    static let queuePanelMinWidth: CGFloat = 280
    static let queuePanelMinWidthCompact: CGFloat = 232
    static let queuePanelMaxWidth: CGFloat = 420
    static let queuePanelMaxWidthCompact: CGFloat = 360
}

struct GlassPanel<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background(panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: SpotiglassDesign.cornerL, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SpotiglassDesign.cornerL, style: .continuous)
                    .strokeBorder(borderStyle, lineWidth: contrast == .increased ? 1.5 : 1)
            }
            .shadow(color: .black.opacity(reduceTransparency ? 0 : 0.12), radius: 18, y: 10)
    }

    @ViewBuilder
    private var panelBackground: some View {
        if reduceTransparency {
            Color(nsColor: .windowBackgroundColor)
        } else {
            Rectangle().fill(.regularMaterial)
        }
    }

    private var borderStyle: Color {
        contrast == .increased ? .primary.opacity(0.35) : .white.opacity(0.18)
    }
}

struct ShellBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Color(nsColor: reduceTransparency ? .windowBackgroundColor : .underPageBackgroundColor)
        .ignoresSafeArea()
    }
}

/// In-app mark matches the running app’s icon (Icon Composer is not a normal `imageset` name). Use the bundle icon from Launch Services, not `Image("AppIcon")` (that looks up the asset catalog and logs “No image named 'AppIcon'…” when the only source is the `.icon` document).
struct SpotiglassBrandLogo: View {
    var length: CGFloat = 72

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: length, height: length)
            .accessibilityLabel("\(AppMetadata.displayName) logo")
    }
}

struct StatusPill: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .padding(.horizontal, SpotiglassDesign.spacingS)
            .padding(.vertical, SpotiglassDesign.spacingXS)
            .background(.secondary.opacity(0.14), in: Capsule())
    }
}
