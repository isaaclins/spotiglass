import SwiftUI

/// The circular "pinned" badge overlaid on artwork.
///
/// This exists because the same badge was previously drawn at six call sites
/// with three glyph sizes (9, 10, 11) and three padding pairs (3+2, 4+4, 5+4),
/// so the pin visibly changed size and inset depending on which screen you were
/// on. One component owns the glyph, the padding and the colors; call sites pick
/// only a scale, which is tied to how large the artwork underneath is.
struct PinnedBadge: View {
    enum Scale {
        /// Row-sized artwork, roughly 40 to 56 points.
        case compact
        /// Header and card artwork, roughly 104 points and up.
        case prominent

        var glyphSize: CGFloat {
            switch self {
            case .compact: 9
            case .prominent: 11
            }
        }

        var innerPadding: CGFloat {
            switch self {
            case .compact: 3
            case .prominent: 4
            }
        }

        var outerPadding: CGFloat {
            switch self {
            case .compact: 2
            case .prominent: 4
            }
        }
    }

    var scale: Scale = .compact

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(systemName: "pin.fill")
            .font(.system(size: scale.glyphSize, weight: .semibold))
            .foregroundStyle(SpotiglassDesign.mediaBadgeForegroundColor(colorScheme: colorScheme))
            .padding(scale.innerPadding)
            .background(
                Circle().fill(SpotiglassDesign.mediaBadgeBackgroundColor(colorScheme: colorScheme))
            )
            .padding(scale.outerPadding)
            .help(SpotiglassL10n.string("browser.pinned"))
            .accessibilityLabel(SpotiglassL10n.string("browser.pinned"))
    }
}

/// A symbol on the same tile as a missing cover, for sidebar rows and destinations that have no
/// artwork of their own (Search, Home, Liked Songs), so they line up with the covers around them.
struct SymbolArtwork: View {
    let systemImage: String
    let size: CGFloat
    /// Draws the symbol in the accent color (Liked Songs while it is the current destination).
    var isEmphasized: Bool = false
    var cornerRadius: CGFloat = SpotiglassDesign.cornerS

    @Environment(\.colorScheme) private var colorScheme

    /// Keeps the glyph proportional to the tile instead of hard-coding a size
    /// per call site.
    private var glyphSize: CGFloat { max(SpotiglassDesign.spacingS, size * 0.42) }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.secondary.opacity(0.16))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: glyphSize, weight: .semibold))
                    .foregroundStyle(
                        isEmphasized
                            ? AnyShapeStyle(SpotiglassAccentStyle())
                            : AnyShapeStyle(.secondary)
                    )
                    .symbolRenderingMode(.monochrome)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        SpotiglassDesign.artworkBorderColor(colorScheme: colorScheme),
                        lineWidth: 1
                    )
            }
            .accessibilityHidden(true)
    }
}

/// Placeholder artwork for Liked Songs, which has no cover image of its own.
///
/// Previously drawn four different ways. Three surfaces used a secondary fill
/// with an accent-tinted heart and a border, while the Home tile used a
/// hard-coded sRGB gradient with a white heart and no border, so it was the one
/// Liked Songs tile that ignored light mode, the accent color and increased
/// contrast.
struct LikedSongsArtwork: View {
    let size: CGFloat
    /// Filled heart while the row is selected or the tile is the current
    /// destination, matching the sidebar row's behavior.
    var isEmphasized: Bool = false
    var cornerRadius: CGFloat = SpotiglassDesign.cornerS

    var body: some View {
        SymbolArtwork(
            systemImage: isEmphasized ? "heart.fill" : "heart",
            size: size,
            isEmphasized: isEmphasized,
            cornerRadius: cornerRadius
        )
    }
}
