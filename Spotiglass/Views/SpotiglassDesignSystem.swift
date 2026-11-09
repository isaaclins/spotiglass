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

    // MARK: - Layout grid

    /// Every spacing, margin and size in the app is a multiple of this (#428).
    /// The old scale (6, 10, 16, 24, 36) was off the grid and views picked their
    /// own numbers next to it, so edges and centre lines drifted between sections.
    /// `LayoutGridTests` fails when a view hard-codes a spacing number again.
    static let gridUnit: CGFloat = 4

    /// Half a grid step. Only for the gap inside one label: a title over its
    /// subtitle, or a badge's vertical inset. Never between two separate things.
    static let spacingHalf: CGFloat = gridUnit / 2
    static let spacingXXS: CGFloat = gridUnit
    static let spacingXS: CGFloat = gridUnit * 2
    static let spacingS: CGFloat = gridUnit * 3
    static let spacingM: CGFloat = gridUnit * 4
    static let spacingL: CGFloat = gridUnit * 6
    static let spacingXL: CGFloat = gridUnit * 8

    /// Fixed layout values for the things that repeat across surfaces. A view
    /// that needs one of these sizes uses the value here, so two surfaces showing
    /// the same kind of thing can't drift apart.
    enum Layout {
        // MARK: Pages

        /// Inset from a page's edge to its content. Page titles, section titles,
        /// cards and the leading edge of track rows all start on this line.
        static let contentMargin: CGFloat = spacingL
        /// The horizontal inset a macOS `.inset` `List` adds to every row on its own.
        static let insetListMargin: CGFloat = spacingM
        /// What content inside an `.inset` `List` (track lists, the artist page) adds
        /// on top of the list's own inset to land on `contentMargin`.
        static let insetListContentInset: CGFloat = contentMargin - insetListMargin
        /// Gap between two sections of a page.
        static let sectionSpacing: CGFloat = spacingL
        /// Gap between a section's title and its content.
        static let sectionTitleSpacing: CGFloat = spacingS
        /// Inset of the narrow side panels (queue, sidebar header) from their edges.
        static let panelMargin: CGFloat = spacingM

        // MARK: Rows

        /// Height of every row that renders a track: artwork plus the row's padding.
        static let trackRowHeight: CGFloat = trackRowArtworkSize + 2 * spacingXS
        static let trackRowArtworkSize: CGFloat = 40
        /// The track number or play button column in front of a track's artwork.
        static let trackNumberColumnWidth: CGFloat = 40
        /// Room for `m:ss` and `mm:ss` durations, so resizing doesn't reflow the trailing edge.
        static let durationColumnWidth: CGFloat = 48
        /// The cover or symbol tile at the leading edge of every sidebar row: Search, Home,
        /// pins, Liked Songs and playlists all use this one size (#444).
        static let sidebarRowArtworkSize: CGFloat = 32
        /// Height of every sidebar row: its tile plus a grid step above and below, which also
        /// fits a title over a subtitle.
        static let sidebarRowHeight: CGFloat = sidebarRowArtworkSize + 2 * spacingXXS
        /// Artwork of command palette results; rows without artwork reserve the same width.
        static let smallArtworkSize: CGFloat = 28
        /// Artwork of a pinned item's drag preview and other inline thumbnails.
        static let thumbnailSize: CGFloat = 24
        /// Widest a pinned item's drag preview gets before its title truncates.
        static let dragPreviewMaxWidth: CGFloat = 260
        /// Artwork of the up-next rows beside the lyrics.
        static let compactRowArtworkSize: CGFloat = 36
        /// The cover at the leading edge of the player bar. Also the player bar's
        /// content height, so a bar that stands in for it keeps the same height.
        static let nowPlayingArtworkSize: CGFloat = 44
        /// Height of a home quick-access tile, which is also its artwork size.
        static let quickAccessTileHeight: CGFloat = 56
        static let quickAccessTileMinWidth: CGFloat = 220
        /// Smallest height a section keeps while it loads or shows a notice, so it doesn't jump.
        static let sectionNoticeMinHeight: CGFloat = 56

        // MARK: Cards

        /// Width of every album, playlist and artist card (Home, Search, artist pages).
        static let cardWidth: CGFloat = 152
        /// Artwork of the large now-playing cover beside the lyrics.
        static let lyricsArtworkSize: CGFloat = 220
        /// The small cover beside the title above the lyrics in a narrow window.
        static let lyricsCompactArtworkSize: CGFloat = 64
        /// Smallest height the lyrics column keeps while it loads, so the layout doesn't jump.
        static let lyricsStatusMinHeight: CGFloat = 160
        /// Smallest height of the "instrumental" note in place of lyrics.
        static let lyricsInstrumentalMinHeight: CGFloat = 120
        /// Widest the now-playing column beside the lyrics gets.
        static let lyricsSideColumnMaxWidth: CGFloat = 320
        /// Smallest height the lyrics column keeps in a short window.
        static let lyricsColumnMinHeight: CGFloat = 200
        /// Artwork on the service choice buttons of the welcome screen.
        static let serviceChoiceLogoSize: CGFloat = 44
        static let serviceChoiceWidth: CGFloat = 192

        // MARK: Controls

        /// Square hit area of an icon button (player bar, palette, queue).
        static let iconButtonSize: CGFloat = 28
        static let iconButtonFrame = CGSize(width: iconButtonSize, height: iconButtonSize)
        /// A button that sits inline with a line of text (the lyrics button beside the title).
        static let inlineButtonSize: CGFloat = 24
        static let inlineButtonFrame = CGSize(width: inlineButtonSize, height: inlineButtonSize)
        /// Square frame of a small glyph next to a label (palette rows, toolbar).
        static let iconSize: CGFloat = 16
        /// Smallest width of the elapsed and remaining times beside the scrubber.
        static let timeLabelMinWidth: CGFloat = 40
        /// Width of the player bar's recovery and device buttons.
        static let wideButtonWidth: CGFloat = 168
        static let wideButtonFrame = CGSize(width: wideButtonWidth, height: iconButtonSize)
        /// Inset of a small text badge ("Explicit", "Unavailable", "Owner").
        static let badgeInsets = EdgeInsets(
            top: spacingHalf, leading: spacingXS, bottom: spacingHalf, trailing: spacingXS
        )
        /// Smallest width of a value readout beside a slider or field.
        static let valueLabelMinWidth: CGFloat = 48

        // MARK: Readable widths

        /// Widest a short message (empty and error states) runs before it wraps.
        static let messageMaxWidth: CGFloat = 360
        /// Widest a longer explanation runs before it wraps.
        static let paragraphMaxWidth: CGFloat = 420
        /// Widest a centered panel (welcome, sign-in) gets.
        static let panelMaxWidth: CGFloat = 560

        /// Widest one breadcrumb gets in the toolbar before it truncates.
        static let breadcrumbMaxWidth: CGFloat = 220
        /// The back button at the leading edge of the toolbar.
        static let toolbarButtonSize: CGFloat = 32

        /// Width of the library prefetch progress bar in the toolbar.
        static let toolbarProgressWidth: CGFloat = 72

        // MARK: Settings

        /// Widest a pop-up picker in a Settings row gets.
        static let pickerMaxWidth: CGFloat = 240
        /// Width of a signed gain readout ("-12.0 dB") in the equalizer.
        static let gainLabelWidth: CGFloat = 64
        /// Smallest width of one equalizer band column, so frequency labels don't clip.
        static let equalizerBandMinWidth: CGFloat = 52
        /// Height of an equalizer band's vertical slider.
        static let equalizerSliderHeight: CGFloat = 200
        /// Width of a small sheet (save preset, rename).
        static let sheetWidth: CGFloat = 380
        /// Smallest a shortcut field gets, so assigned and empty fields read as one control.
        /// Width of every shortcut field in Settings > Keyboard, bound or not.
        /// Fits the longest state in every language ("Zum Aufzeichnen klicken",
        /// or recording with all four modifiers held), so no row grows.
        static let shortcutFieldWidth: CGFloat = 176
        static let shortcutFieldMinHeight: CGFloat = 28
        /// Smallest height of a multi-line text editor in Settings.
        static let textEditorMinHeight: CGFloat = 200
        /// Smallest size of the keyboard settings when shown in a window of their own.
        static let standaloneSettingsMinWidth: CGFloat = 720
        static let standaloneSettingsMinHeight: CGFloat = 520

        // MARK: Command palette

        static let paletteMaxWidth: CGFloat = 760
        static let paletteResultsHeight: CGFloat = 360
        /// Widest the palette's prefetch progress bar gets.
        static let paletteProgressMaxWidth: CGFloat = 140
    }

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
    static let settingsProfileAvatarSize: CGFloat = 32
    static let settingsHeaderIconSize: CGFloat = 28
    static let settingsSidebarIconSize: CGFloat = 24

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
    /// Small artwork in dense rows (the sidebar). `cornerS` on a 32 pt tile rounds it into an
    /// app icon; covers that small read as covers with a quarter of that.
    static let cornerXS: CGFloat = 4
    static let cornerS: CGFloat = 8
    static let cornerM: CGFloat = 14
    static let cornerL: CGFloat = 22

    static let sidebarWidth: CGFloat = 320

    // MARK: - Narrow window (playlist sidebar + queue + detail)

    static let playlistSidebarMinWidth: CGFloat = 280
    static let detailColumnMinWidth: CGFloat = 360
    static let queuePanelMinWidth: CGFloat = 280

    /// Below this content width the playlist sidebar and detail column cannot
    /// both honor their declared minimums, so the browser collapses the sidebar.
    static let playlistSidebarAndDetailMinWidth: CGFloat =
        playlistSidebarMinWidth + detailColumnMinWidth

    static let queuePanelMaxWidth: CGFloat = 420

    /// The narrowest the browser gets while the queue panel is open: the detail column and the
    /// queue side by side at their minimums. The window can't be made narrower than this with
    /// the queue showing, so the panel is never cut off at the window's edge (#413).
    static let detailAndQueueMinWidth: CGFloat = detailColumnMinWidth + queuePanelMinWidth

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

