import SwiftUI

// MARK: - Section header

/// Title row above a home section ("Recently played", "Your top tracks").
struct HomeSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title2.weight(.bold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Quick-access tile

/// Wide horizontal tile in the home quick-access grid. Small leading artwork
/// (or a Liked Songs gradient) with a bold title.
struct HomeQuickAccessTile: View {
    let card: HomeMediaCard
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
            .frame(height: 56)
            .frame(maxWidth: .infinity, alignment: .leading)
            .spotiglassSurface(corner: .s, fill: .background.secondary)
            .contentShape(RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverPressable(hoverScale: 1.015, pressScale: 0.985)
        .accessibilityLabel(card.title)
    }

    @ViewBuilder
    private var artwork: some View {
        switch card.destination {
        case .likedSongs:
            RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.30, green: 0.20, blue: 0.85), Color(red: 0.45, green: 0.70, blue: 0.95)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 56, height: 56)
                .overlay {
                    Image(systemName: "heart.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                }
        default:
            ArtworkView(url: card.artworkURL, size: 56)
        }
    }
}

// MARK: - Carousel card

/// Square "jump back in" card used in the Recently played carousel.
struct HomeMediaCardView: View {
    let card: HomeMediaCard
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
                ArtworkView(url: card.artworkURL, size: 150)
                Text(card.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(card.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverPressable(hoverScale: 1.03, pressScale: 0.97)
        .accessibilityLabel("\(card.title), \(card.subtitle)")
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
            case .message(let icon, let text):
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                Text(text)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 60)
    }
}
