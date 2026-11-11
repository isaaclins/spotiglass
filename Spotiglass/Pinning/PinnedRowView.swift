import SwiftUI

/// One pinned-item row, laid out by `SidebarRow` like every other sidebar row.
/// Owns the hover-only ✕ unpin button and
/// stale-state visuals; drag/reorder lives on the Library sidebar host view.
struct PinnedRowView: View {
    let item: PinnedItem
    /// Sidebar selection currently bound to this row (drives the same
    /// highlight as a regular playlist row).
    var isSelected: Bool = false
    let onUnpin: () -> Void

    @State private var isHovering: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.spotiglassLocale) private var spotiglassLocale
    private let artworkSize = SpotiglassDesign.Layout.sidebarRowArtworkSize

    var body: some View {
        SidebarRow(subtitle: item.localizedSubtitle(locale: spotiglassLocale)) {
            artwork
        } title: {
            HStack(spacing: SpotiglassDesign.spacingXS) {
                Text(item.localizedTitle(locale: spotiglassLocale))
                    .foregroundStyle(item.isStale ? Color.secondary : Color.primary)
                if item.isStale {
                    // The badge explains the state, so it must be the most
                    // legible thing in the row, not the least (#144).
                    Text(SpotiglassL10n.string("pin.unavailable", locale: spotiglassLocale))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.primary)
                        .padding(SpotiglassDesign.Layout.badgeInsets)
                        .background(.quaternary, in: Capsule())
                        // The row's one-line limit cuts the title, never the badge that explains it.
                        .fixedSize()
                }
            }
        } accessory: {
            // At the trailing end on hover, like Finder's eject button, rather than over the
            // cover's corner (#444).
            if isHovering {
                Button(action: onUnpin) {
                    Image(systemName: "xmark.circle.fill")
                        .font(SpotiglassDesign.Typography.pinRemove)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(SpotiglassL10n.string("tooltip.pin.unpin", locale: spotiglassLocale))
                .accessibilityLabel(String(format: SpotiglassL10n.string("pin.unpin"), item.localizedTitle(locale: spotiglassLocale)))
            }
        }
        // Staleness is carried by the badge and the demoted title. Fading the
        // whole row multiplied 55% onto text that is already secondary, which
        // put the subtitle near 30% effective opacity and made the badge that
        // explains the state the hardest thing in the row to read (#144).
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            String(
                format: SpotiglassL10n.string("pin.row.accessibility", locale: spotiglassLocale),
                item.kind.accessibilityLabel(locale: spotiglassLocale),
                item.localizedTitle(locale: spotiglassLocale),
                item.localizedSubtitle(locale: spotiglassLocale),
                item.isStale ? SpotiglassL10n.string("pin.row.unavailable", locale: spotiglassLocale) : ""
            )
        )
    }

    @ViewBuilder
    private var artwork: some View {
        switch item.kind {
        case .likedSongs:
            LikedSongsArtwork(size: artworkSize, isEmphasized: isSelected, cornerRadius: SpotiglassDesign.cornerXS)
        case .artist:
            ZStack {
                Circle().fill(.secondary.opacity(0.16))
                if let url = item.artworkURL {
                    CachedCircularArtwork(url: url, diameter: artworkSize, artworkKey: item.id)
                } else {
                    Image(systemName: "person.wave.2")
                        .font(SpotiglassDesign.Typography.pinArtistFallback)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: artworkSize, height: artworkSize)
            .clipShape(Circle())
            .overlay { Circle().strokeBorder(SpotiglassDesign.artworkBorderColor(colorScheme: colorScheme), lineWidth: 1) }
        case .playlist, .album, .track:
            ArtworkView(url: item.artworkURL, size: artworkSize, artworkKey: item.id, cornerRadius: SpotiglassDesign.cornerXS)
        }
    }
}

private struct CachedCircularArtwork: View {
    let url: URL
    let diameter: CGFloat
    /// The pin's ID, so an Apple Music library cover saved last session still resolves.
    var artworkKey: String? = nil
    @StateObject private var artworkLoader = ArtworkImageLoader()
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let requestURL = ArtworkRequest.url(url, points: diameter, scale: displayScale, itemKey: artworkKey)
        Group {
            if let image = artworkLoader.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                MusicKitArtwork(url: url, width: diameter, height: diameter, itemKey: artworkKey)
            }
        }
        .frame(width: diameter, height: diameter)
        .task(id: requestURL.absoluteString) {
            await artworkLoader.load(for: requestURL, artwork: url)
        }
    }
}

private extension PinnedItemKind {
    func accessibilityLabel(locale: Locale = SpotiglassL10n.locale) -> String {
        switch self {
        case .playlist: SpotiglassL10n.string("pin.kind.playlist", locale: locale)
        case .artist: SpotiglassL10n.string("pin.kind.artist", locale: locale)
        case .album: SpotiglassL10n.string("pin.kind.album", locale: locale)
        case .track: SpotiglassL10n.string("pin.kind.track", locale: locale)
        case .likedSongs: SpotiglassL10n.string("pin.likedSongs", locale: locale)
        }
    }
}

/// Compact pill drag preview shown under the cursor for any pinning drag —
/// dragging a source row into the sidebar, reordering inside the pinned area,
/// or dragging a pinned row out to unpin. SF Symbol per kind + truncated title.
struct PinnedItemDragPill: View {
    let item: PinnedItem
    private let artworkSize = SpotiglassDesign.Layout.thumbnailSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.spotiglassLocale) private var spotiglassLocale

    var body: some View {
        HStack(spacing: SpotiglassDesign.spacingXS) {
            previewArtwork

            Image(systemName: kindSymbolName)
                .font(SpotiglassDesign.Typography.pinKind)
                .foregroundStyle(.spotiglassAccent)
            VStack(alignment: .leading, spacing: SpotiglassDesign.spacingHalf) {
                Text(item.localizedTitle(locale: spotiglassLocale))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !item.localizedSubtitle(locale: spotiglassLocale).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(item.localizedSubtitle(locale: spotiglassLocale))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .frame(maxWidth: SpotiglassDesign.Layout.dragPreviewMaxWidth, alignment: .leading)
        .spotiglassPillBackground(variant: .material(.regularMaterial))
    }

    @ViewBuilder
    private var previewArtwork: some View {
        switch item.kind {
        case .likedSongs:
            RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
                .fill(.secondary.opacity(0.16))
                .frame(width: artworkSize, height: artworkSize)
                .overlay {
                    Image(systemName: "heart.fill")
                        .font(SpotiglassDesign.Typography.pinKind)
                        .foregroundStyle(.spotiglassAccent)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
                        .strokeBorder(SpotiglassDesign.artworkBorderColor(colorScheme: colorScheme), lineWidth: 1)
                }
        case .artist:
            ZStack {
                Circle().fill(.secondary.opacity(0.16))
                if let url = item.artworkURL,
                    let cover = DragPreviewArtwork.initialImage(artworkURL: url, requestURL: nil, artworkKey: item.id)
                {
                    // A library artist's cover only draws in a window; take it from the screen (#449).
                    Image(nsImage: cover)
                        .resizable()
                        .scaledToFill()
                } else if let url = item.artworkURL, !AppleMusicArtworkRegistry.needsMusicKit(url) {
                    CachedCircularArtwork(url: url, diameter: artworkSize, artworkKey: item.id)
                } else {
                    // A library cover not drawn on screen can't be drawn into the drag image at
                    // all: MusicKit's view needs a window.
                    Image(systemName: "person.wave.2")
                        .font(SpotiglassDesign.Typography.pinKind)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: artworkSize, height: artworkSize)
            .clipShape(Circle())
            .overlay { Circle().strokeBorder(SpotiglassDesign.artworkBorderColor(colorScheme: colorScheme), lineWidth: 1) }
        case .playlist, .album, .track:
            DragPreviewArtwork(url: item.artworkURL, size: artworkSize, artworkKey: item.id)
        }
    }

    private var kindSymbolName: String {
        switch item.kind {
        case .playlist: "music.note.list"
        case .artist: "person.wave.2"
        case .album: "opticaldisc"
        case .track: "music.note"
        case .likedSongs: "heart.fill"
        }
    }
}

struct DragPreviewArtwork: View {
    let url: URL?
    let size: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var artworkLoader: ArtworkImageLoader

    init(url: URL?, size: CGFloat, artworkKey: String? = nil) {
        // The same sized URL the pin row draws, so the preview finds its cover in the cache.
        let artworkURL = url
        let url = url.map {
            ArtworkRequest.url($0, points: size, scale: NSScreen.main?.backingScaleFactor ?? 2, itemKey: artworkKey)
        }
        self.url = url
        self.size = size
        let initialImage = Self.initialImage(artworkURL: artworkURL, requestURL: url, artworkKey: artworkKey)
        _artworkLoader = StateObject(
            wrappedValue: ArtworkImageLoader(
                initialImage: initialImage,
                initialURL: url
            )
        )
    }

    /// The cover the preview has the moment the drag begins: macOS takes the drag image right
    /// away, so a cover that loads later never shows. Downloaded covers come from the disk cache.
    /// Library covers (`musicKit://`) are never there and only MusicKit draws them, so they are
    /// taken from a view that shows that cover on screen, such as the row being dragged (#449).
    @MainActor
    static func initialImage(
        artworkURL: URL?,
        requestURL: URL?,
        artworkKey: String?
    ) -> NSImage? {
        guard let artworkURL else { return nil }
        if AppleMusicArtworkRegistry.needsMusicKit(artworkURL) {
            return OnScreenArtwork.shared.snapshot(url: artworkURL, itemKey: artworkKey)
        }
        return requestURL.flatMap { ArtworkImageStore.cachedImageIfAvailable(for: $0) }
    }

    var body: some View {
        Group {
            if let image = artworkLoader.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
                    .fill(.secondary.opacity(0.16))
                    .overlay {
                        Image(systemName: "music.note")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
                .strokeBorder(SpotiglassDesign.artworkBorderColor(colorScheme: colorScheme), lineWidth: 1)
        }
        .task(id: url?.absoluteString ?? "") {
            await artworkLoader.load(for: url)
        }
    }
}
