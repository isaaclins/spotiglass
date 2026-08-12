import SwiftUI

// MARK: - Motion

/// App-wide motion tokens. Reuse instead of defining one-off `Animation` constants.
///
/// These springs were tuned alongside the immersive lyrics teleprompter; they
/// share the same feel so settings, palette pills, and lyrics motion all match.
enum SpotiglassMotion {
    /// Snappy spring for interactive control feedback (hover scale, press scale,
    /// pill selection changes). Settles in ~0.35s with no overshoot.
    static let controlSpring: Animation = .spring(response: 0.32, dampingFraction: 0.86)

    /// Slightly slower spring for surface / card content changes (size pickers,
    /// settings tab swaps).
    static let surfaceSpring: Animation = .spring(response: 0.42, dampingFraction: 0.82)

    /// Spring used for transitions that swap one view for another (pill enter/exit).
    static let transitionSpring: Animation = .spring(response: 0.46, dampingFraction: 0.82)
}

// MARK: - Pill button style

/// Capsule-shaped button chrome used for floating action pills, chips, and
/// segmented-style category selectors. Replaces ad-hoc
/// `Capsule()` + material + manual hover/press scale layering at call sites.
struct SpotiglassPillStyle: ButtonStyle {
    enum Variant {
        /// Translucent capsule (`.ultraThinMaterial`) with a subtle white gradient
        /// overlay — for floating pills on dark or busy backdrops (e.g. the
        /// immersive lyrics "Return to current line" pill).
        case glass
        /// Plain material capsule — calmer, for chrome inside opaque surfaces.
        case material(Material)
        /// Solid accent fill — use for the selected segment in a row of pills.
        case accent
    }

    var variant: Variant = .glass
    var horizontalPadding: CGFloat = SpotiglassDesign.spacingM
    var verticalPadding: CGFloat = SpotiglassDesign.spacingS

    func makeBody(configuration: Configuration) -> some View {
        SpotiglassPillStyleBody(
            configuration: configuration,
            variant: variant,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding
        )
    }
}

private struct SpotiglassPillStyleBody: View {
    let configuration: ButtonStyleConfiguration
    let variant: SpotiglassPillStyle.Variant
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appearsActive) private var appearsActive
    @State private var isHovering = false

    var body: some View {
        label
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background {
                pillFill(variant: variant, isHovering: isHovering)
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 0.6)
            }
            .contentShape(Capsule(style: .continuous))
            .scaleEffect(scale)
            .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowY)
            .onHover { isHovering = $0 }
            .animation(SpotiglassMotion.controlSpring, value: isHovering)
            .animation(SpotiglassMotion.controlSpring, value: configuration.isPressed)
    }

    /// Only `.accent` needs an explicit label color: it is the one variant that paints a
    /// solid fill behind the title, and that fill turns white in a background window.
    /// `.glass` and `.material` keep the inherited foreground so their call sites can
    /// still tint their own labels.
    @ViewBuilder private var label: some View {
        switch variant {
        case .accent:
            configuration.label
                .foregroundStyle(SpotiglassDesign.onAccent(appearsActive: appearsActive))
        case .glass, .material:
            configuration.label
        }
    }

    private var scale: CGFloat {
        if configuration.isPressed { return 0.95 }
        if isHovering { return 1.03 }
        return 1.0
    }

    private var borderColor: Color {
        switch variant {
        case .glass:
            return .white.opacity(isHovering ? 0.32 : 0.20)
        case .material:
            return SpotiglassDesign.chromeCapsuleBorderColor(colorScheme: colorScheme)
        case .accent:
            return .white.opacity(0.18)
        }
    }

    private var shadowColor: Color {
        switch variant {
        case .glass: return .black.opacity(0.45)
        case .material: return .black.opacity(0.18)
        case .accent: return .black.opacity(0.22)
        }
    }

    private var shadowRadius: CGFloat {
        switch variant {
        case .glass: return 14
        case .material: return 8
        case .accent: return 10
        }
    }

    private var shadowY: CGFloat {
        switch variant {
        case .glass: return 6
        case .material: return 3
        case .accent: return 4
        }
    }
}

@ViewBuilder
private func pillFill(variant: SpotiglassPillStyle.Variant, isHovering: Bool) -> some View {
    switch variant {
    case .glass:
        ZStack {
            Capsule(style: .continuous).fill(.ultraThinMaterial)
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(isHovering ? 0.18 : 0.10),
                            .white.opacity(isHovering ? 0.06 : 0.02)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    case .material(let material):
        Capsule(style: .continuous).fill(material)
    case .accent:
        Capsule(style: .continuous).fill(.spotiglassAccent)
    }
}

// MARK: - Pill background modifier (non-Button)

/// Applies the same capsule chrome as `SpotiglassPillStyle` to non-interactive
/// views — drag previews, badges, decorative chips.
struct SpotiglassPillBackgroundModifier: ViewModifier {
    let variant: SpotiglassPillStyle.Variant
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background {
                pillFill(variant: variant, isHovering: false)
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 0.6)
            }
    }

    private var borderColor: Color {
        switch variant {
        case .glass:
            return .white.opacity(0.20)
        case .material:
            return SpotiglassDesign.chromeCapsuleBorderColor(colorScheme: colorScheme)
        case .accent:
            return .white.opacity(0.18)
        }
    }
}

extension View {
    /// Wraps the receiver in a capsule with the requested chrome — same look as
    /// a ``SpotiglassPillStyle`` button, but without interactive scaling.
    func spotiglassPillBackground(
        variant: SpotiglassPillStyle.Variant = .glass,
        horizontalPadding: CGFloat = SpotiglassDesign.spacingS,
        verticalPadding: CGFloat = SpotiglassDesign.spacingXS
    ) -> some View {
        modifier(SpotiglassPillBackgroundModifier(
            variant: variant,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding
        ))
    }
}

// MARK: - Surface (card) modifier

/// Rounded-rectangle card chrome used for settings tiles, preview tiles, and
/// tab buttons. Replaces the repeated
/// `RoundedRectangle(cornerRadius:, style: .continuous).fill(...).strokeBorder(...)`
/// pattern.
struct SpotiglassSurfaceModifier: ViewModifier {
    enum CornerSize {
        case s, m, l

        var radius: CGFloat {
            switch self {
            case .s: return SpotiglassDesign.cornerS
            case .m: return SpotiglassDesign.cornerM
            case .l: return SpotiglassDesign.cornerL
            }
        }
    }

    let corner: CornerSize
    let fill: AnyShapeStyle
    let strokeStyle: AnyShapeStyle
    let strokeWidth: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: corner.radius, style: .continuous)
                    .fill(fill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: corner.radius, style: .continuous)
                    .strokeBorder(strokeStyle, lineWidth: strokeWidth)
            }
    }
}

extension View {
    /// Applies a rounded-rectangle surface with a fill and stroke.
    /// Use the default styling for "settings tile" feel, or override for
    /// selection / emphasis states.
    func spotiglassSurface(
        corner: SpotiglassSurfaceModifier.CornerSize = .m,
        fill: some ShapeStyle = .background.secondary,
        stroke: some ShapeStyle = AnyShapeStyle(HierarchicalShapeStyle.quaternary),
        strokeWidth: CGFloat = 0.5
    ) -> some View {
        modifier(SpotiglassSurfaceModifier(
            corner: corner,
            fill: AnyShapeStyle(fill),
            strokeStyle: AnyShapeStyle(stroke),
            strokeWidth: strokeWidth
        ))
    }
}

// MARK: - Hover-pressable modifier (for non-Button views)

/// Adds a tuned hover + press spring scale to any view. Use when the view
/// can't be a `Button` (custom gestures, drag handles) but should still feel
/// like a Spotiglass control.
struct HoverPressableModifier: ViewModifier {
    var hoverScale: CGFloat = 1.03
    var pressScale: CGFloat = 0.95

    @State private var isHovering = false
    @State private var isPressed = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? pressScale : (isHovering ? hoverScale : 1.0))
            .onHover { isHovering = $0 }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isPressed = true }
                    .onEnded { _ in isPressed = false }
            )
            .animation(SpotiglassMotion.controlSpring, value: isHovering)
            .animation(SpotiglassMotion.controlSpring, value: isPressed)
    }
}

extension View {
    /// Adds a consistent hover/press spring scale. Equivalent feel to
    /// ``SpotiglassPillStyle`` for views that aren't buttons.
    func hoverPressable(hoverScale: CGFloat = 1.03, pressScale: CGFloat = 0.95) -> some View {
        modifier(HoverPressableModifier(hoverScale: hoverScale, pressScale: pressScale))
    }
}
