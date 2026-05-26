import SwiftUI

struct PlaylistBrowserDetailWithQueueSplit<Main: View, Queue: View>: View {
    @Binding var unifiedRefreshFocus: UnifiedRefreshFocus
    let isQueueVisible: Bool
    @ViewBuilder let mainColumn: () -> Main
    @ViewBuilder let queueColumn: () -> Queue

    var body: some View {
        HStack(spacing: 0) {
            mainColumn()
                .background(.background)
                .frame(minWidth: SpotiglassDesign.detailColumnMinWidth)
                .layoutPriority(1)
                .onHover { hovering in
                    if hovering { unifiedRefreshFocus = .mainContent }
                }
            if isQueueVisible {
                queueColumn()
                    .transition(
                        .asymmetric(
                            insertion: .offset(x: SpotiglassDesign.sidebarWidth).combined(with: .opacity),
                            removal: .offset(x: SpotiglassDesign.sidebarWidth).combined(with: .opacity)
                        )
                    )
                    .onHover { hovering in
                        if hovering { unifiedRefreshFocus = .queuePanel }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.38, dampingFraction: 0.84), value: isQueueVisible)
    }
}

struct QueuePanelColumn: View {
    @ObservedObject var queueViewModel: QueueViewModel
    @ObservedObject var playbackViewModel: PlaybackSessionViewModel
    let openArtist: (ArtistTapTarget) -> Void

    var body: some View {
        QueuePanelView(
            queueViewModel: queueViewModel,
            playbackViewModel: playbackViewModel,
            openArtist: openArtist
        )
        .background(.background)
        .frame(
            minWidth: SpotiglassDesign.queuePanelMinWidth,
            idealWidth: SpotiglassDesign.sidebarWidth,
            maxWidth: SpotiglassDesign.queuePanelMaxWidth
        )
    }
}

struct PlaylistBrowserMainDetailColumn: View {
    @ObservedObject var viewModel: PlaylistBrowserViewModel
    @ObservedObject var playbackViewModel: PlaybackSessionViewModel
    @ObservedObject var queueViewModel: QueueViewModel
    @EnvironmentObject private var lyricsOverlay: LyricsOverlayController

    @Binding var pendingPlaylistListScrollRestoreID: String?
    @Binding var detailLastVisibleTrackID: String?

    let currentPlaybackURI: String?
    let isCurrentlyPlaying: Bool
    let hasPlaybackDevice: Bool

    var body: some View {
        VStack(spacing: 0) {
            switch viewModel.detailState {
            case .loading:
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .loaded(content), let .refreshing(content), let .staleCache(content, _):
                Group {
                    if lyricsOverlay.isPresented {
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityHidden(true)
                    } else {
                        switch content {
                        case let .playlist(detail):
                            PlaylistDetailContent(
                                detail: detail,
                                currentUserSpotifyID: viewModel.currentUserSpotifyID,
                                pendingScrollRestoreTrackID: $pendingPlaylistListScrollRestoreID,
                                onTrackEnteredViewportApproximation: { detailLastVisibleTrackID = $0 },
                                playURI: { uri in
                                    let playableURIs = detail.tracks.compactMap(\.playableURI)
                                    let playlistID = detail.playlist.id
                                    Task {
                                        await playbackViewModel.playFromPlaylist(
                                            clickedURI: uri,
                                            playableURIs: playableURIs,
                                            playlistID: playlistID
                                        )
                                    }
                                },
                                currentPlaybackURI: currentPlaybackURI,
                                isPlaying: isCurrentlyPlaying,
                                togglePlayPause: {
                                    Task { await playbackViewModel.togglePlayPause() }
                                },
                                hasPlaybackDevice: hasPlaybackDevice,
                                addToQueue: { uri in
                                    await queueViewModel.addToQueue(uri: uri)
                                },
                                openArtist: { artistID in
                                    Task { await viewModel.selectArtist(id: artistID, origin: .extend, displayName: nil) }
                                }
                            )
                        case let .artist(detail):
                            ArtistDetailContent(
                                detail: detail,
                                playTrack: { uri in
                                    let playableURIs = detail.tracks.compactMap(\.playableURI)
                                    Task {
                                        await playbackViewModel.playFromPlaylist(
                                            clickedURI: uri,
                                            playableURIs: playableURIs,
                                            playlistID: nil
                                        )
                                    }
                                },
                                openAlbum: { album in
                                    Task {
                                        await viewModel.selectAlbum(
                                            id: album.id,
                                            displayTitle: album.title,
                                            displaySubtitle: detail.artist.name,
                                            artworkURL: album.artworkURL,
                                            origin: .extend
                                        )
                                    }
                                },
                                playAlbumContext: { albumURI in
                                    Task { await playbackViewModel.play(contextURI: albumURI) }
                                },
                                currentPlaybackURI: currentPlaybackURI,
                                isPlaying: isCurrentlyPlaying,
                                togglePlayPause: {
                                    Task { await playbackViewModel.togglePlayPause() }
                                },
                                hasPlaybackDevice: hasPlaybackDevice,
                                addToQueue: { uri in
                                    await queueViewModel.addToQueue(uri: uri)
                                },
                                openArtist: { artistID in
                                    Task { await viewModel.selectArtist(id: artistID, origin: .extend, displayName: nil) }
                                },
                                loadMoreAlbums: {
                                    Task { await viewModel.loadMoreArtistAlbums() }
                                }
                            )
                        }
                    }
                }
                .overlay(alignment: .bottom) {
                    if case let .staleCache(_, error) = viewModel.detailState {
                        StaleCacheBanner(error: error)
                    } else if case .refreshing = viewModel.detailState {
                        ProgressView(SpotiglassL10n.string("browser.refreshingDetail"))
                            .controlSize(.small)
                            .padding(SpotiglassDesign.spacingS)
                            .background(.background, in: Capsule())
                            .padding(SpotiglassDesign.spacingM)
                    }
                }
            case let .empty(message):
                EmptyStateView(title: SpotiglassL10n.string("browser.noTracks.title"), message: message)
            case let .error(error):
                ErrorStateView(error: error)
            }
        }
    }
}
