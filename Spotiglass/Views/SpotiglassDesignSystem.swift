import AppKit
import SwiftUI

enum SpotiglassDesign {
    /// System accent used by native controls (sliders, progress, focus), matching
    /// the Accent color chosen in System Settings.
    static var controlAccent: Color {
        Color(nsColor: .controlAccentColor)
    }

    // MARK: - Inactive window appearance

    /// How much of the accent's color survives while its window is not the key window.
    /// Zero matches AppKit, which paints a background window's controls in grey rather
    /// than in a washed out tint.
    static let inactiveWindowAccentSaturation: CGFloat = 0

    /// The accent a custom drawn control should paint with, given whether its window is key.
    ///
    /// macOS colors only the key window's controls, so a background window's accents turn
    /// grey. AppKit does that for its own controls and SwiftUI does it for the standard
    /// ones; anything this app draws by hand has to opt in, and this is where it opts in.
    /// Prefer `SpotiglassAccentStyle` at the call site so the environment read stays here.
    static func accent(appearsActive: Bool) -> Color {
        appearsActive ? controlAccent : inactiveAccent
    }

    /// `controlAccent` with the color drained out but the brightness kept, so a subdued
    /// control still reads at the same visual weight instead of fading off the surface.
    ///
    /// Stored rather than computed so repeated reads compare equal: SwiftUI diffs a view's
    /// colors by value, and a freshly built dynamic color would look like a change on every
    /// update. The provider still resolves the live accent per appearance, so light and dark
    /// each get their own grey.
    static let inactiveAccent = Color(nsColor: NSColor(name: nil) { appearance in
        var resolved = NSColor.controlAccentColor
        appearance.performAsCurrentDrawingAppearance {
            resolved = subduedForInactiveWindow(.controlAccentColor)
        }
        return resolved
    })

    /// Scales the saturation of `nsColor` while keeping its hue, brightness and alpha.
    /// Split out from `inactiveAccent` because the accent itself is a live system color,
    /// so this is the part that can be pinned down in a test.
    static func subduedForInactiveWindow(
        _ nsColor: NSColor,
        saturationScale: CGFloat = inactiveWindowAccentSaturation
    ) -> NSColor {
        guard let rgb = nsColor.usingColorSpace(.sRGB) else { return nsColor }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return NSColor(
            hue: hue,
            saturation: max(0, min(1, saturation * saturationScale)),
            brightness: brightness,
            alpha: alpha
        )
    }

    /// Foreground for label content drawn on top of an ``accent(appearsActive:)`` fill.
    ///
    /// A fixed white label is wrong here. ``subduedForInactiveWindow(_:saturationScale:)``
    /// keeps the accent's brightness while dropping its saturation, so the default bright
    /// blue accent resolves to plain white in a background window, and white on white is
    /// invisible. Pick the label from the fill's luminance instead, so the selected control
    /// stays readable both while the window is key and while it is not.
    static func onAccent(appearsActive: Bool) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                var fill = NSColor.controlAccentColor
                appearance.performAsCurrentDrawingAppearance {
                    fill =
                        appearsActive
                        ? .controlAccentColor
                        : subduedForInactiveWindow(.controlAccentColor)
                }
                return contrastingLabel(on: fill)
            })
    }

    /// A light or dark label, whichever stays legible on `background`.
    ///
    /// Deliberately not the raw WCAG crossover at 0.179. macOS paints white on
    /// `controlAccentColor`, and the default blue sits at luminance 0.21, so the strict
    /// crossover would flip every accent control to black text and stop looking like a Mac.
    /// The job here is only to stop the label disappearing, which happens when the drained
    /// inactive accent turns near white, so the flip waits until the fill is genuinely light.
    static func contrastingLabel(on background: NSColor) -> NSColor {
        guard let rgb = background.usingColorSpace(.sRGB) else { return .white }
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        let luminance =
            0.2126 * linear(rgb.redComponent)
            + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
        return luminance > 0.5 ? .black : .white
    }

    static let spacingXS: CGFloat = 6
    static let spacingS: CGFloat = 10
    static let spacingM: CGFloat = 16
    static let spacingL: CGFloat = 24
    static let spacingXL: CGFloat = 36

    // MARK: - Dynamic typography

    /// Semantic fonts for compact custom chrome. Text styles follow the user's
    /// accessibility text-size setting; fixed-point `Font.system(size:)` does not.
    enum Typography {
        static let breadcrumb = Font.footnote
        static let commandPaletteIcon = Font.body.weight(.medium)
        static let commandPaletteClearShortcut = Font.body
        static let commandPaletteEmptyState = Font.largeTitle
        static let commandPaletteArtworkFallback = Font.footnote.weight(.medium)
        static let pinRemove = Font.body.weight(.bold)
        static let pinArtistFallback = Font.title3.weight(.semibold)
        static let pinKind = Font.caption.weight(.semibold)
        static let settingsHeaderIcon = Font.body.weight(.semibold)
        static let settingsSidebarIcon = Font.caption.weight(.semibold)
        static let appearanceSliderSmall = Font.caption.weight(.semibold)
        static let appearanceSliderLarge = Font.title3.weight(.semibold)
    }

    // MARK: - Settings chrome

    /// Geometry shared by the Settings shell and its native controls.
    /// Keeping these values here prevents the shell from becoming a second
    /// source of spacing, card and window-size rules.
    static let settingsWindowWidth: CGFloat = 980
    static let settingsWindowMinHeight: CGFloat = 660
    static let settingsSidebarMinWidth: CGFloat = 220
    static let settingsSidebarIdealWidth: CGFloat = 240
    static let settingsSidebarMaxWidth: CGFloat = 280
    static let settingsProfileAvatarSize: CGFloat = 34
    static let settingsHeaderIconSize: CGFloat = 28
    static let settingsSidebarIconSize: CGFloat = 22

    // MARK: - Playback chrome

    /// Width of the accent rail that marks a selected track without reusing the
    /// current-track waveform affordance.
    static let trackSelectionIndicatorWidth: CGFloat = 3

    /// Marquee speed for an overflowing now-playing artist line. Keeping the
    /// value with the other visual tokens prevents a view from inventing its
    /// own motion scale.
    static let nowPlayingArtistLineScrollPointsPerSecond: CGFloat = 24
    static let nowPlayingArtistLineMinimumScrollDuration: TimeInterval = 2
    static let nowPlayingArtistLineScrollPause: Duration = .seconds(1)

    /// Artwork size for the playlist, Liked Songs and artist detail headers.
    /// One value so equivalent headers cannot drift apart (#145).
    static let detailHeaderArtworkSize: CGFloat = 120
    static let cornerS: CGFloat = 8
    static let cornerM: CGFloat = 14
    static let cornerL: CGFloat = 22

    static let sidebarWidth: CGFloat = 320

    // MARK: - Narrow window (playlist sidebar + queue + detail)

    static let playlistSidebarMinWidth: CGFloat = 280
    static let detailColumnMinWidth: CGFloat = 360
    static let queuePanelMinWidth: CGFloat = 280

    /// Minimum main-window width that keeps the playlist sidebar and detail
    /// columns fully visible. macOS does not collapse this two-column split
    /// when its visibility is explicitly bound, so the window must not accept
    /// the old 520pt width (#356).
    static let browserWindowMinWidth: CGFloat = 700
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

    /// Unplayed portion of the scrubber. This used to be a fixed 35% neutral
    /// gray, the only one in the view layer: very low contrast on the light-mode
    /// control background, and blind to increased contrast, while the thumb
    /// right next to it already branched on both.
    static func scrubberTrackColor(colorScheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
        let opacity: Double = contrast == .increased ? 0.55 : 0.30
        switch colorScheme {
        case .dark:
            return .white.opacity(opacity)
        default:
            return .black.opacity(opacity)
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

/// The app's accent as a `ShapeStyle`, greyed automatically while its window is not key.
///
/// This is the single place the inactive window decision is made for custom drawn UI.
/// Because a `ShapeStyle` resolves against the environment it is handed, every call site
/// gets the behavior without reading `\.appearsActive` itself, which keeps the rule in one
/// file instead of scattered across two dozen views.
///
/// Use it anywhere a `ShapeStyle` is accepted: `.foregroundStyle(.spotiglassAccent)`,
/// `.fill(.spotiglassAccent)`, or `SpotiglassAccentStyle().opacity(0.18)` when it needs
/// to be softened.
struct SpotiglassAccentStyle: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color {
        SpotiglassDesign.accent(appearsActive: environment.appearsActive)
    }
}

extension ShapeStyle where Self == SpotiglassAccentStyle {
    /// The system accent, greyed automatically while its window is not the key window.
    static var spotiglassAccent: SpotiglassAccentStyle { SpotiglassAccentStyle() }
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

