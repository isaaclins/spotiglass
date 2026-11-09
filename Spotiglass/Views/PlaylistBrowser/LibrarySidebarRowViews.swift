import SwiftUI

/// The one row layout of the sidebar (#444): a tile, a title with an optional subtitle under it,
/// and what the row needs to say about itself at the trailing end.
///
/// Every row used to be shaped on its own: Search and Home were slim system labels with a
/// glyph, playlists and pins tall rows with a 48 pt cover, and each badge sat on the cover. Now
/// every row has the same height and tile size, so tiles, titles and subtitles form straight
/// columns down the whole sidebar, the way the rows of Finder, Music and Spotify's library do.
struct SidebarRow<Artwork: View, Title: View, Accessory: View>: View {
    var subtitle: String?
    @ViewBuilder let artwork: () -> Artwork
    @ViewBuilder let title: () -> Title
    @ViewBuilder let accessory: () -> Accessory

    init(
        subtitle: String? = nil,
        @ViewBuilder artwork: @escaping () -> Artwork,
        @ViewBuilder title: @escaping () -> Title,
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }
    ) {
        self.subtitle = subtitle
        self.artwork = artwork
        self.title = title
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: SpotiglassDesign.spacingXS) {
            artwork()
                .frame(width: Self.artworkSize, height: Self.artworkSize)
            VStack(alignment: .leading, spacing: SpotiglassDesign.spacingHalf) {
                title()
                    .font(.body)
                    .lineLimit(1)
                if let subtitle {
                    // A count still loading (or unknown) leaves the line blank but keeps its
                    // height, so rows don't jump when the count arrives.
                    Text(subtitle.nonEmptyLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            accessory()
        }
        // A floor, not a cap: content that ever outgrows it makes the row taller instead of
        // drawing over the next one, and `SidebarRowLayoutTests` notices.
        .frame(minHeight: SpotiglassDesign.Layout.sidebarRowHeight)
        .contentShape(Rectangle())
    }

    static var artworkSize: CGFloat { SpotiglassDesign.Layout.sidebarRowArtworkSize }
}

/// What a sidebar row says about itself at its trailing end, where Music and Spotify put it,
/// instead of on the cover: pinned, and now playing.
struct SidebarRowStatus: View {
    var isPinned = false
    var isNowPlaying = false
    var isPlaying = false

    var body: some View {
        if isPinned || isNowPlaying {
            HStack(spacing: SpotiglassDesign.spacingXS) {
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help(SpotiglassL10n.string("browser.pinned"))
                }
                if isNowPlaying {
                    PlayingWaveformIcon(isPlaying: isPlaying)
                }
            }
            .accessibilityHidden(true)
        }
    }
}

/// A sidebar destination without artwork of its own (Search, Home), drawn as a symbol tile so it
/// lines up with the covers below it.
struct SidebarDestinationRow: View {
    let titleKey: String
    let systemImage: String

    var body: some View {
        SidebarRow {
            SymbolArtwork(
                systemImage: systemImage,
                size: SpotiglassDesign.Layout.sidebarRowArtworkSize,
                cornerRadius: SpotiglassDesign.cornerXS
            )
        } title: {
            L10nText(titleKey)
        }
        .accessibilityElement(children: .combine)
    }
}

struct LibraryHomeSidebarRow: View {
    var body: some View {
        SidebarDestinationRow(titleKey: "browser.home", systemImage: "house")
    }
}

struct PinnedSidebarLibraryRow: View {
    let item: PinnedItem
    let isSelected: Bool
    @EnvironmentObject private var pinnedStore: PinnedItemsStore
    @Environment(\.spotiglassLocale) private var spotiglassLocale

    var body: some View {
        PinnedRowView(
            item: item,
            isSelected: isSelected,
            onUnpin: { pinnedStore.unpin(id: item.id) }
        )
        .contextMenu {
            Button(SpotiglassL10n.string("browser.unpin.short", locale: spotiglassLocale)) { pinnedStore.unpin(id: item.id) }
        }
    }
}
