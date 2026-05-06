import SwiftUI

struct ArtistDetailContent: View {
    let detail: ArtistDetailViewModel
    /// Starts playback of one track; caller supplies playlist-style queue of URIs.
    let playTrack: (String) -> Void
    let playAlbumContext: (String) -> Void
    let currentPlaybackURI: String?
    let isPlaying: Bool
    let togglePlayPause: () -> Void
    let hasPlaybackDevice: Bool
    let addToQueue: (String) async -> Void
    let openArtist: (String) -> Void

    @EnvironmentObject private var pinnedStore: PinnedItemsStore

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
                    Text("Tracks")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, SpotiglassDesign.spacingL)
                    tracksSection
                }
                albumStrip(title: "Albums", albums: detail.albums, group: .album)
                albumStrip(title: "Singles", albums: detail.singles, group: .single)
                albumStrip(title: "Compilations", albums: detail.compilations, group: .compilation)
                albumStrip(title: "Appears on", albums: detail.appearsOn, group: .appearsOn)
            }
            .padding(.vertical, SpotiglassDesign.spacingM)
        }
        .acceptsPinnedDropOut(store: pinnedStore)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: SpotiglassDesign.spacingL) {
            ArtworkView(url: detail.artist.imageURL, size: 120)
                .clipShape(RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if isArtistPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                            .padding(4)
                            .accessibilityLabel("Pinned to sidebar")
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
        .draggable(
            PinnedItemTransfer(
                item: .artist(detail.artist),
                originScopeID: "artistHeader:\(artistID)"
            )
        ) {
            PinnedItemDragPill(item: .artist(detail.artist))
        }
        .contextMenu {
            if isArtistPinned {
                Button("Unpin from Sidebar") {
                    pinnedStore.unpin(id: PinnedItem.id(forKind: .artist, spotifyID: artistID))
                }
            } else {
                Button("Pin to Sidebar") {
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
                    tracksSurfaceID: tracksSurfaceID,
                    originPlaylistID: nil
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
        return Button {
            playAlbumContext(album.uri)
        } label: {
            albumCard(album, showPinGlyph: pinned)
        }
        .buttonStyle(.plain)
        .draggable(
            PinnedItemTransfer(
                item: pinnedItem,
                originScopeID: "artistAlbums:\(artistID)"
            )
        ) {
            PinnedItemDragPill(item: pinnedItem)
        }
        .contextMenu {
            if pinned {
                Button("Unpin from Sidebar") { pinnedStore.unpin(id: pinnedItem.id) }
            } else {
                Button("Pin to Sidebar") { pinnedStore.pin(pinnedItem) }
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
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Circle().fill(Color.black.opacity(0.55)))
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
}
