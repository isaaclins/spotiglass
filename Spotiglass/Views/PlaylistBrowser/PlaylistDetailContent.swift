import SwiftUI

struct PlaylistDetailContent: View {
    let detail: PlaylistDetailViewModel
    @Binding var pendingScrollRestoreTrackID: String?
    let onTrackEnteredViewportApproximation: (String) -> Void
    let playURI: (String) -> Void
    let currentPlaybackURI: String?
    let isPlaying: Bool
    let togglePlayPause: () -> Void
    let hasPlaybackDevice: Bool
    let addToQueue: (String) async -> Void
    let openArtist: (String) -> Void

    @EnvironmentObject private var pinnedStore: PinnedItemsStore

    private var tracksSurfaceKey: String { "pl:\(detail.playlist.id)" }

    private var originPlaylistIDForTracks: String? {
        detail.playlist.id == SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID ? nil : detail.playlist.id
    }

    private var headerPinnedItem: PinnedItem {
        if detail.playlist.id == SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID {
            .likedSongs(ownerDisplay: detail.playlist.owner, artworkURL: detail.playlist.artworkURL)
        } else {
            .playlist(
                SpotifyPlaylistSummary(
                    id: detail.playlist.id,
                    name: detail.playlist.title,
                    ownerName: detail.playlist.owner,
                    imageURL: detail.playlist.artworkURL,
                    trackCount: 0,
                    snapshotID: detail.playlist.snapshotID
                )
            )
        }
    }

    private var isHeaderPinned: Bool {
        pinnedStore.isPinned(id: headerPinnedItem.id)
    }

    private var supportsHeaderPinning: Bool {
        detail.playlist.id != SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBlock

            Divider()

            if detail.tracks.isEmpty {
                EmptyStateView(title: "No tracks", message: "This playlist is empty.")
            } else {
                VirtualizedTrackList(
                    tracks: detail.tracks,
                    rowBuilder: { track in
                        TrackListRow(
                            trackNumber: track.listPosition,
                            track: track,
                            playURI: playURI,
                            togglePlayPause: togglePlayPause,
                            isCurrent: track.playableURI != nil && track.playableURI == currentPlaybackURI,
                            isPlaying: isPlaying,
                            hasPlaybackDevice: hasPlaybackDevice,
                            addToQueue: addToQueue,
                            openArtist: openArtist,
                            tracksSurfaceID: tracksSurfaceKey,
                            originPlaylistID: originPlaylistIDForTracks
                        )
                    },
                    pendingScrollRestoreTrackID: $pendingScrollRestoreTrackID,
                    onFirstVisibleTrackChanged: onTrackEnteredViewportApproximation
                )
            }
        }
    }

    private var headerBlock: some View {
        HStack(alignment: .center, spacing: SpotiglassDesign.spacingL) {
            Group {
                if detail.playlist.id == SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID {
                    RoundedRectangle(cornerRadius: SpotiglassDesign.cornerM, style: .continuous)
                        .fill(.secondary.opacity(0.16))
                        .frame(width: 104, height: 104)
                        .overlay {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 44, weight: .semibold))
                                .foregroundStyle(SpotiglassDesign.controlAccent)
                                .symbolRenderingMode(.monochrome)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: SpotiglassDesign.cornerM, style: .continuous)
                                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                        }
                        .overlay(alignment: .topTrailing) {
                            if isHeaderPinned {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(5)
                                    .background(Circle().fill(Color.black.opacity(0.55)))
                                    .padding(4)
                            }
                        }
                } else {
                    ArtworkView(url: detail.playlist.artworkURL, size: 104)
                        .overlay(alignment: .topTrailing) {
                            if isHeaderPinned {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(5)
                                    .background(Circle().fill(Color.black.opacity(0.55)))
                                    .padding(4)
                            }
                        }
                }
            }

            VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
                Text(detail.playlist.title)
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(2)

                Text("\(detail.playlist.owner) • \(detail.playlist.trackCountText)")
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(SpotiglassDesign.spacingL)
        .modifier(LibraryHeaderPinningModifier(
            supportsHeaderPinning: supportsHeaderPinning,
            headerPinnedItem: headerPinnedItem,
            tracksSurfaceKey: tracksSurfaceKey,
            isHeaderPinned: isHeaderPinned,
            pinnedStore: pinnedStore
        ))
    }
}

struct LibraryHeaderPinningModifier: ViewModifier {
    let supportsHeaderPinning: Bool
    let headerPinnedItem: PinnedItem
    let tracksSurfaceKey: String
    let isHeaderPinned: Bool
    let pinnedStore: PinnedItemsStore

    @ViewBuilder
    func body(content: Content) -> some View {
        if supportsHeaderPinning {
            content
                .onDrag(
                    {
                        PinnedItemTransfer(
                            item: headerPinnedItem,
                            originScopeID: tracksSurfaceKey
                        ).itemProvider()
                    },
                    preview: {
                        PinnedItemDragPill(item: headerPinnedItem)
                    }
                )
                .contextMenu {
                    if isHeaderPinned {
                        Button("Unpin from Sidebar") {
                            pinnedStore.unpin(id: headerPinnedItem.id)
                        }
                    } else {
                        Button("Pin to Sidebar") {
                            pinnedStore.pin(headerPinnedItem)
                        }
                    }
                }
        } else {
            content
        }
    }
}
