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
            }
            .padding(.vertical, SpotiglassDesign.spacingM)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: SpotiglassDesign.spacingL) {
            ArtworkView(url: detail.artist.imageURL, size: 120)
                .clipShape(RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if isArtistPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SpotiglassDesign.mediaBadgeForegroundColor(colorScheme: colorScheme))
                            .padding(4)
                            .background(
                                Circle().fill(SpotiglassDesign.mediaBadgeBackgroundColor(colorScheme: colorScheme))
                            )
                            .padding(4)
                            .accessibilityLabel(SpotiglassL10n.string("browser.pinned"))
                    }
                }

            VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
                Text(detail.artist.name)
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(2)

                if let followers = detail.artist.followersTotal {
                    Text(NumberFormatter.localizedString(from: NSNumber(value: followers), number: .decimal) + " followers")
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
        .onDrag(
            {
                PinnedItemTransfer(
                    item: .artist(detail.artist),
                    originScopeID: "artistHeader:\(artistID)"
                ).itemProvider()
            },
            preview: {
                PinnedItemDragPill(item: .artist(detail.artist))
            }
        )
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

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: SpotiglassDesign.spacingM) {
                        ForEach(albums) { album in
                            albumCardButton(album, group: group)
                        }
                    }
                    .padding(.horizontal, SpotiglassDesign.spacingL)
                    .padding(.bottom, SpotiglassDesign.spacingS)
                }
            }
        }
    }

    private func albumCardButton(_ album: ArtistAlbumRowViewModel, group: SpotifyArtistAlbumGroup) -> some View {
        let pinnedItem = album.pinnedAlbum(group: group)
        let pinned = pinnedStore.isPinned(id: pinnedItem.id)
        return albumCard(album, showPinGlyph: pinned)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            albumTapRouter.handleDoubleTap {
                openAlbum(album)
                playAlbumContext(album.uri)
            }
        }
        .onTapGesture {
            albumTapRouter.handleSingleTap(albumID: album.id) {
                openAlbum(album)
            }
        }
        .onDrag(
            {
                PinnedItemTransfer(
                    item: pinnedItem,
                    originScopeID: "artistAlbums:\(artistID)"
                ).itemProvider()
            },
            preview: {
                PinnedItemDragPill(item: pinnedItem)
            }
        )
        .contextMenu {
            if pinned {
                Button(SpotiglassL10n.string("browser.unpin")) { pinnedStore.unpin(id: pinnedItem.id) }
            } else {
                Button(SpotiglassL10n.string("browser.pin")) { pinnedStore.pin(pinnedItem) }
            }
        }
    }

    private func albumCard(_ album: ArtistAlbumRowViewModel, showPinGlyph: Bool) -> some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
            ArtworkView(url: album.artworkURL, size: 132)
                .clipShape(RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if showPinGlyph {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(SpotiglassDesign.mediaBadgeForegroundColor(colorScheme: colorScheme))
                            .padding(4)
                            .background(
                                Circle().fill(SpotiglassDesign.mediaBadgeBackgroundColor(colorScheme: colorScheme))
                            )
                            .padding(4)
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
