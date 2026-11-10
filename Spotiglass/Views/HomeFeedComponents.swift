import SwiftUI

// MARK: - Section header

/// Title row above a home section ("Recently played", "Your top tracks").
struct HomeSectionHeader: View {
    /// The page title is explicit so a caller cannot lose its hierarchy to the
    /// reusable section-heading default (#212).
    enum Style: Equatable {
        case pageTitle
        case section

        var textStyle: Font.TextStyle {
            switch self {
            case .pageTitle:
                .largeTitle
            case .section:
                .title2
            }
        }

        var font: Font {
            .system(textStyle).weight(.bold)
        }
    }

    let title: String
    let style: Style

    init(title: String, style: Style = .section) {
        self.title = title
        self.style = style
    }

    var body: some View {
        Text(title)
            .font(style.font)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Quick-access tile

/// Wide horizontal tile in the home quick-access grid. Small leading artwork
/// (or a Liked Songs gradient) with a bold title.
struct HomeQuickAccessTile: View {
    let card: HomeMediaCard
    let browserViewModel: PlaylistBrowserViewModel
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                artwork
                Text(card.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, SpotiglassDesign.spacingS)
                Spacer(minLength: 0)
            }
            .frame(height: SpotiglassDesign.Layout.quickAccessTileHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .spotiglassSurface(corner: .s, fill: .background.secondary)
            .contentShape(RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverPressable(hoverScale: 1.015, pressScale: 0.985)
        .accessibilityLabel(card.title)
        // The same menu the playlist has in the sidebar (#478).
        .collectionContextMenu(card.menuTarget, browserViewModel: browserViewModel)
    }

    @ViewBuilder
    private var artwork: some View {
        switch card.destination {
        case .likedSongs:
            // Was the only Liked Songs tile in the app painted from fixed sRGB
            // values, so it ignored light mode, the accent color and increased
            // contrast while the sidebar and header versions honored all three.
            LikedSongsArtwork(size: SpotiglassDesign.Layout.quickAccessTileHeight, isEmphasized: true)
        default:
            ArtworkView(url: card.artworkURL, size: SpotiglassDesign.Layout.quickAccessTileHeight)
        }
    }
}

// MARK: - Carousel card

/// Square "jump back in" card used in the Recently played carousel and the search results.
/// The cover and the title open the album or playlist; each artist name under it opens that
/// artist, and right-clicking anywhere on the card shows the item's menu (#478).
struct HomeMediaCardView: View {
    static let artworkSize = SpotiglassDesign.Layout.cardWidth

    let card: HomeMediaCard
    let browserViewModel: PlaylistBrowserViewModel
    let openArtist: (MusicArtistRef) -> Void
    let action: () -> Void

    @State private var isTitleHovered = false

    private var hasArtistLinks: Bool {
        card.artistCredits.contains { if case .link = $0 { true } else { false } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
                    ArtworkView(url: card.artworkURL, size: Self.artworkSize)
                    Text(card.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .underline(isTitleHovered)
                        .onHover { isTitleHovered = $0 }
                        .pointerStyle(.link)
                    // A line without links (a playlist's owner, an artist without an ID) is
                    // part of the card's button, so clicking it opens the item as it always did.
                    if !hasArtistLinks {
                        HomeCardArtistCredits(subtitle: card.subtitle, credits: [], openArtist: openArtist)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(card.title), \(card.subtitle)")
            // VoiceOver and keyboard users reach the menu from the card's own button.
            .collectionAccessibilityActions(card.menuTarget, browserViewModel: browserViewModel)

            if hasArtistLinks {
                HomeCardArtistCredits(subtitle: card.subtitle, credits: card.artistCredits, openArtist: openArtist)
            }
        }
        .frame(width: Self.artworkSize, alignment: .leading)
        .contentShape(Rectangle())
        .hoverPressable(hoverScale: 1.03, pressScale: 0.97)
        .collectionContextMenu(card.menuTarget, browserViewModel: browserViewModel, includesAccessibilityActions: false)
    }
}

/// The artist line under a card: one link per artist whose ID the service gave, the other
/// names as plain text.
struct HomeCardArtistCredits: View {
    let subtitle: String
    let credits: [HomeArtistCredit]
    let openArtist: (MusicArtistRef) -> Void

    var body: some View {
        if !credits.contains(where: { if case .link = $0 { true } else { false } }) {
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityHidden(true)
        } else {
            HStack(spacing: 0) {
                ForEach(Array(credits.enumerated()), id: \.offset) { index, credit in
                    if index > 0 {
                        Text(SpotiglassL10n.string("common.comma"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    switch credit {
                    case let .link(artist):
                        Button {
                            openArtist(artist)
                        } label: {
                            Text(artist.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .buttonStyle(.spotiglassTextLink)
                        .accessibilityLabel(SpotiglassL10n.format("playback.controls.openArtist", artist.name))
                    case let .name(name):
                        Text(name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .accessibilityHidden(true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Section placeholders

/// Inline status row shown when a home section is loading, empty, scope-gated,
/// or failed — keeps section height stable without a hard error surface.
struct HomeSectionNotice: View {
    enum Style {
        case loading
        case message(icon: String, text: String)
    }

    let style: Style

    var body: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            switch style {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                Text(SpotiglassL10n.string("home.section.loading"))
                    .foregroundStyle(.secondary)
            case let .message(icon, text):
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                Text(text)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: SpotiglassDesign.Layout.sectionNoticeMinHeight)
    }
}
