import SwiftUI

@MainActor
final class AlbumCardTapRouter: ObservableObject {
    private var pendingSingleTapTask: Task<Void, Never>?
    private var pendingSingleTapID: String?
    private let doubleClickDelayNanoseconds: UInt64

    init(doubleClickDelayNanoseconds: UInt64 = 250_000_000) {
        self.doubleClickDelayNanoseconds = doubleClickDelayNanoseconds
    }

    func handleSingleTap(albumID: String, onOpen: @escaping () -> Void) {
        pendingSingleTapTask?.cancel()
        pendingSingleTapID = albumID
        pendingSingleTapTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: doubleClickDelayNanoseconds)
            guard let self else { return }
            guard !Task.isCancelled, self.pendingSingleTapID == albumID else { return }
            onOpen()
            self.pendingSingleTapID = nil
            self.pendingSingleTapTask = nil
        }
    }

    func handleDoubleTap(onOpenAndPlay: () -> Void) {
        pendingSingleTapTask?.cancel()
        pendingSingleTapTask = nil
        pendingSingleTapID = nil
        onOpenAndPlay()
    }
}

struct ArtistDetailContent: View {
    let detail: ArtistDetailViewModel
    /// Starts playback of one track; caller supplies playlist-style queue of URIs.
    let playTrack: (String) -> Void
    let openAlbum: (ArtistAlbumRowViewModel) -> Void
    let playAlbumContext: (String) -> Void
    let currentPlaybackURI: String?
    let isPlaying: Bool
    let togglePlayPause: () -> Void
    let hasPlaybackDevice: Bool
    let addToQueue: (String) async -> Void
    let openArtist: (String) -> Void
    let loadMoreAlbums: () -> Void

    @EnvironmentObject private var pinnedStore: PinnedItemsStore
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var albumTapRouter = AlbumCardTapRouter()

    private var artistID: String { detail.artist.id }
    private var tracksSurfaceID: String { "ar:\(artistID)" }

    private var isArtistPinned: Bool {
        pinnedStore.isPinned(spotifyID: artistID, kind: .artist)
    }

    private var hasNothingToShow: Bool {
        detail.tracks.isEmpty
            && detail.albums.isEmpty
            && detail.singles.isEmpty
            && detail.compilations.isEmpty
            && detail.appearsOn.isEmpty
            && !detail.canLoadMoreAlbums
            && !detail.isLoadingMoreAlbums
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SpotiglassDesign.spacingL) {
                header
                if !detail.tracks.isEmpty {
                    Text(SpotiglassL10n.string("browser.tracks"))
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, SpotiglassDesign.spacingL)
                    tracksSection
                }
                albumStrip(title: SpotiglassL10n.string("browser.albums"), albums: detail.albums, group: .album)
                albumStrip(title: SpotiglassL10n.string("browser.singles"), albums: detail.singles, group: .single)
                albumStrip(title: SpotiglassL10n.string("browser.compilations"), albums: detail.compilations, group: .compilation)
                albumStrip(title: SpotiglassL10n.string("browser.appearsOn"), albums: detail.appearsOn, group: .appearsOn)
                if detail.canLoadMoreAlbums || detail.isLoadingMoreAlbums {
                    loadMoreButton
                        .padding(.horizontal, SpotiglassDesign.spacingL)
                }
                if hasNothingToShow {
                    // Every section above is guarded and albumStrip returns
                    // EmptyView for an empty array, so an artist with no tracks
                    // and no releases used to render a header over a void, while
                    // the sibling playlist screen explains itself (#135).
                    EmptyStateView(
                        title: SpotiglassL10n.string("browser.artist.empty.title"),
                        message: SpotiglassL10n.string("browser.artist.empty.message")
                    )
                }
            }
            .padding(.vertical, SpotiglassDesign.spacingM)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: SpotiglassDesign.spacingL) {
            CircularArtworkView(url: detail.artist.imageURL, size: SpotiglassDesign.detailHeaderArtworkSize)
                .overlay(alignment: .topTrailing) {
                    if isArtistPinned {
                        PinnedBadge(scale: .prominent)
                    }
                }

            VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
                Text(detail.artist.name)
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(2)

                if let followers = detail.artist.followersTotal {
                    // The count was localized and then had an English noun glued
                    // on with +, which also froze the word order (#152).
                    Text(
                        SpotiglassL10n.format(
                            "browser.artist.followers",
                            NumberFormatter.localizedString(
                                from: NSNumber(value: followers),
                                number: .decimal
                            )
                        )
                    )
                    .foregroundStyle(.secondary)
                }

                if !detail.artist.genres.isEmpty {
                    Text(detail.artist.genres.prefix(6).joined(separator: " • "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()
        }
        .padding(.horizontal, SpotiglassDesign.spacingL)
        .draggable(PinnedItemTransfer(item: .artist(detail.artist))) {
            PinnedItemDragPill(item: .artist(detail.artist))
        }
        .contextMenu {
            if isArtistPinned {
                Button(SpotiglassL10n.string("browser.unpin")) {
                    pinnedStore.unpin(id: PinnedItem.id(forKind: .artist, spotifyID: artistID))
                }
            } else {
                Button(SpotiglassL10n.string("browser.pin")) {
                    pinnedStore.pin(.artist(detail.artist))
                }
            }
        }
    }

    private var tracksSection: some View {
        LazyVStack(spacing: 0) {
            ForEach(detail.tracks) { track in
                TrackListRow(
                    trackNumber: track.listPosition,
                    track: track,
                    playURI: playTrack,
                    togglePlayPause: togglePlayPause,
                    isCurrent: track.playableURI != nil && track.playableURI == currentPlaybackURI,
                    isPlaying: isPlaying,
                    hasPlaybackDevice: hasPlaybackDevice,
                    addToQueue: addToQueue,
                    openArtist: openArtist,
                    tracksSurfaceID: tracksSurfaceID
                )
            }
        }
        .padding(.horizontal, SpotiglassDesign.spacingS)
    }

    @ViewBuilder
    private func albumStrip(title: String, albums: [ArtistAlbumRowViewModel], group: SpotifyArtistAlbumGroup) -> some View {
        if albums.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, SpotiglassDesign.spacingL)

                // Keep the shelf discoverable and settle it on whole release cards,
                // matching the resolved Home shelf behavior (#232).
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: SpotiglassDesign.spacingM) {
                        ForEach(albums) { album in
                            albumCardButton(album, group: group)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, SpotiglassDesign.spacingL)
                    .padding(.bottom, SpotiglassDesign.spacingS)
                }
                .scrollTargetBehavior(.viewAligned)
            }
        }
    }

    private func albumCardButton(_ album: ArtistAlbumRowViewModel, group: SpotifyArtistAlbumGroup) -> some View {
        let pinnedItem = album.pinnedAlbum(group: group)
        let pinned = pinnedStore.isPinned(id: pinnedItem.id)
        // A real Button, like the Home and Search cards, so the card is reachable
        // with Tab, activates on Return and reports the button trait (#111, #124).
        // The double click still opens and plays: it runs as a simultaneous
        // gesture and cancels the router's pending single-tap open, which is the
        // same arbitration the two tap gestures used to do between themselves.
        return Button {
            albumTapRouter.handleSingleTap(albumID: album.id) {
                openAlbum(album)
            }
        } label: {
            albumCard(album, showPinGlyph: pinned)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                albumTapRouter.handleDoubleTap {
                    openAlbum(album)
                    playAlbumContext(album.uri)
                }
            }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(albumAccessibilityLabel(album, pinned: pinned))
        .draggable(PinnedItemTransfer(item: pinnedItem)) {
            PinnedItemDragPill(item: pinnedItem)
        }
        .contextMenu {
            if pinned {
                Button(SpotiglassL10n.string("browser.unpin")) { pinnedStore.unpin(id: pinnedItem.id) }
            } else {
                Button(SpotiglassL10n.string("browser.pin")) { pinnedStore.pin(pinnedItem) }
            }
        }
    }

    /// One sentence per card. VoiceOver used to walk the artwork, title, year and
    /// track count as three or four separate fragments (#111).
    private func albumAccessibilityLabel(_ album: ArtistAlbumRowViewModel, pinned: Bool) -> String {
        var parts = [album.title]
        if let year = album.yearText { parts.append(year) }
        parts.append(album.trackCountText)
        if pinned { parts.append(SpotiglassL10n.string("browser.pinned")) }
        return parts.joined(separator: SpotiglassL10n.string("common.comma"))
    }

    private func albumCard(_ album: ArtistAlbumRowViewModel, showPinGlyph: Bool) -> some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
            ArtworkView(url: album.artworkURL, size: 132)
                .clipShape(RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if showPinGlyph {
                        PinnedBadge(scale: .prominent)
                    }
                }

            Text(album.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .frame(width: 132, alignment: .leading)

            if let year = album.yearText {
                Text(year)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(album.trackCountText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 132)
    }

    private var loadMoreButton: some View {
        Button(action: loadMoreAlbums) {
            HStack(spacing: SpotiglassDesign.spacingS) {
                if detail.isLoadingMoreAlbums {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(detail.isLoadingMoreAlbums ? SpotiglassL10n.string("browser.artist.loadingMore") : SpotiglassL10n.string("browser.artist.loadMore"))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(detail.isLoadingMoreAlbums)
    }
}
