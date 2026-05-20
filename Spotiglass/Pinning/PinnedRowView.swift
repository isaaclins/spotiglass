import SwiftUI

/// One pinned-item row, shaped to match `PlaylistListRow` so pinned items feel
/// native to the existing sidebar. Owns the hover-only ✕ unpin badge and
/// stale-state visuals; drag/reorder lives on the Library sidebar host view.
struct PinnedRowView: View {
    let item: PinnedItem
    /// Sidebar selection currently bound to this row (drives the same
    /// highlight as a regular playlist row).
    var isSelected: Bool = false
    let onUnpin: () -> Void

    @State private var isHovering: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    private let artworkSize: CGFloat = 46

    var body: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            artwork
                .overlay(alignment: .topLeading) {
                    if isHovering {
                        Button(action: onUnpin) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16, weight: .bold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .red)
                                .background(
                                    Circle().fill(Color.black.opacity(0.001))
                                )
                        }
                        .buttonStyle(.plain)
                        .offset(x: -6, y: -6)
                        .accessibilityLabel(String(format: SpotiglassL10n.string("pin.unpin"), item.title))
                    }
                }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: SpotiglassDesign.spacingXS) {
                    Text(item.title)
                        .font(.headline)
                        .foregroundStyle(item.isStale ? Color.secondary : Color.primary)
                        .lineLimit(1)
                    if item.isStale {
                        Text(SpotiglassL10n.string("pin.unavailable"))
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.18), in: Capsule())
                    }
                }
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, SpotiglassDesign.spacingXS)
        .opacity(item.isStale ? 0.55 : 1.0)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            String(
                format: SpotiglassL10n.string("pin.row.accessibility"),
                item.kind.accessibilityLabel,
                item.title,
                item.subtitle,
                item.isStale ? SpotiglassL10n.string("pin.row.unavailable") : ""
            )
        )
    }

    @ViewBuilder
    private var artwork: some View {
        switch item.kind {
        case .likedSongs:
            RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
                .fill(.secondary.opacity(0.16))
                .frame(width: artworkSize, height: artworkSize)
                .overlay {
                    Image(systemName: isSelected ? "heart.fill" : "heart")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(isSelected ? SpotiglassDesign.controlAccent : .secondary)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
                        .strokeBorder(SpotiglassDesign.artworkBorderColor(colorScheme: colorScheme), lineWidth: 1)
                }
        case .artist:
            ZStack {
                Circle().fill(.secondary.opacity(0.16))
                if let url = item.artworkURL {
                    CachedCircularArtwork(url: url, diameter: artworkSize)
                } else {
                    Image(systemName: "person.wave.2")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: artworkSize, height: artworkSize)
            .clipShape(Circle())
            .overlay { Circle().strokeBorder(SpotiglassDesign.artworkBorderColor(colorScheme: colorScheme), lineWidth: 1) }
        case .playlist, .album, .track:
            ArtworkView(url: item.artworkURL, size: artworkSize)
        }
    }
}

private struct CachedCircularArtwork: View {
    let url: URL
    let diameter: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.clear
            }
        }
        .frame(width: diameter, height: diameter)
        .task(id: url.absoluteString) {
            image = await ArtworkImageStore.shared.image(for: url)
        }
    }
}

private extension PinnedItemKind {
    var accessibilityLabel: String {
        switch self {
        case .playlist: SpotiglassL10n.string("pin.kind.playlist")
        case .artist: SpotiglassL10n.string("pin.kind.artist")
        case .album: SpotiglassL10n.string("pin.kind.album")
        case .track: SpotiglassL10n.string("pin.kind.track")
        case .likedSongs: SpotiglassL10n.string("pin.likedSongs")
        }
    }
}

/// Compact pill drag preview shown under the cursor for any pinning drag —
/// dragging a source row into the sidebar, reordering inside the pinned area,
/// or dragging a pinned row out to unpin. SF Symbol per kind + truncated title.
struct PinnedItemDragPill: View {
    let item: PinnedItem
    private let artworkSize: CGFloat = 24
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            previewArtwork

            Image(systemName: kindSymbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SpotiglassDesign.controlAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !item.subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(item.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .frame(maxWidth: 260, alignment: .leading)
        .spotiglassPillBackground(
            variant: .material(.regularMaterial),
            horizontalPadding: 10,
            verticalPadding: 6
        )
        .onAppear { PinnedDragPreviewState.shared.beginDrag(item: item) }
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
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SpotiglassDesign.controlAccent)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous)
                        .strokeBorder(SpotiglassDesign.artworkBorderColor(colorScheme: colorScheme), lineWidth: 1)
                }
        case .artist:
            ZStack {
                Circle().fill(.secondary.opacity(0.16))
                if let url = item.artworkURL {
                    CachedCircularArtwork(url: url, diameter: artworkSize)
                } else {
                    Image(systemName: "person.wave.2")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: artworkSize, height: artworkSize)
            .clipShape(Circle())
            .overlay { Circle().strokeBorder(SpotiglassDesign.artworkBorderColor(colorScheme: colorScheme), lineWidth: 1) }
        case .playlist, .album, .track:
            DragPreviewArtwork(url: item.artworkURL, size: artworkSize)
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

private struct DragPreviewArtwork: View {
    let url: URL?
    let size: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: NSImage?

    init(url: URL?, size: CGFloat) {
        self.url = url
        self.size = size
        if let url {
            _image = State(initialValue: ArtworkImageStore.cachedImageIfAvailable(for: url))
        } else {
            _image = State(initialValue: nil)
        }
    }

    var body: some View {
        Group {
            if let image {
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
            guard image == nil, let url else { return }
            image = await ArtworkImageStore.shared.image(for: url)
        }
    }
}
