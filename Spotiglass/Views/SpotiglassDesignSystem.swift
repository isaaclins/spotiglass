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

    static let playlistSidebarMinWidth: CGFloat = 280
    static let detailColumnMinWidth: CGFloat = 360
    static let queuePanelMinWidth: CGFloat = 280
    static let queuePanelMaxWidth: CGFloat = 420

    /// Below this width the playlist sidebar and queue panel are mutually exclusive (opening one closes the other),
    /// so neither side ever clips off-screen. Computed from the natural mins above plus ~80pt of slack for dividers
    /// and rounding, so future tuning of the column mins propagates automatically.
    static let dualSidebarComfortableMinWidth: CGFloat =
        playlistSidebarMinWidth + detailColumnMinWidth + queuePanelMinWidth + 80

    static func glassPanelBorderColor(
        contrast: ColorSchemeContrast,
        colorScheme: ColorScheme
    ) -> Color {
        if contrast == .increased {
            return .primary.opacity(0.35)
        }
        switch colorScheme {
        case .dark:
            return .white.opacity(0.18)
        default:
            return .black.opacity(0.10)
        }
    }

    static func artworkBorderColor(colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .dark:
            return .white.opacity(0.14)
        default:
            return .black.opacity(0.10)
        }
    }

    static func chromeCapsuleBorderColor(colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .dark:
            return .white.opacity(0.12)
        default:
            return .black.opacity(0.08)
        }
    }

    static func mediaBadgeForegroundColor(colorScheme: ColorScheme) -> Color {
        .white
    }

    static func mediaBadgeBackgroundColor(colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .dark:
            return .black.opacity(0.55)
        default:
            return .black.opacity(0.48)
        }
    }

    static func scrubberThumbFillColor(colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .dark:
            return .white
        default:
            return Color(nsColor: .controlBackgroundColor)
        }
    }

    static func scrubberThumbBorderColor(colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .dark:
            return .black.opacity(0.18)
        default:
            return .black.opacity(0.14)
        }
    }
}

struct GlassPanel<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

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
        SpotiglassDesign.glassPanelBorderColor(contrast: contrast, colorScheme: colorScheme)
    }
}

struct ShellBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Color(nsColor: reduceTransparency ? .windowBackgroundColor : .underPageBackgroundColor)
        .ignoresSafeArea()
    }
}

