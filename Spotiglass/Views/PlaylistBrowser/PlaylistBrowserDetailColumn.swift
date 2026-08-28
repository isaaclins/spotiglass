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
    @ObservedObject var browserViewModel: PlaylistBrowserViewModel
    @ObservedObject var queueViewModel: QueueViewModel
    @ObservedObject var playbackViewModel: PlaybackSessionViewModel
    let openArtist: (ArtistTapTarget) -> Void
    let onRequestCreatePlaylist: (([TrackRowViewModel]) -> Void)?
    let onRequestLibraryContinuation: ((TrackRowViewModel) -> Void)?

    init(
        browserViewModel: PlaylistBrowserViewModel,
        queueViewModel: QueueViewModel,
        playbackViewModel: PlaybackSessionViewModel,
        openArtist: @escaping (ArtistTapTarget) -> Void,
        onRequestCreatePlaylist: (([TrackRowViewModel]) -> Void)? = nil,
        onRequestLibraryContinuation: ((TrackRowViewModel) -> Void)? = nil
    ) {
        _browserViewModel = ObservedObject(wrappedValue: browserViewModel)
        _queueViewModel = ObservedObject(wrappedValue: queueViewModel)
        _playbackViewModel = ObservedObject(wrappedValue: playbackViewModel)
        self.openArtist = openArtist
        self.onRequestCreatePlaylist = onRequestCreatePlaylist
        self.onRequestLibraryContinuation = onRequestLibraryContinuation
    }

    var body: some View {
        QueuePanelView(
            queueViewModel: queueViewModel,
            playbackViewModel: playbackViewModel,
            openArtist: openArtist,
            trackOpsMenuItems: { item in
                AnyView(TrackOpsMenuItems(
                    targets: [TrackRowViewModel(queueItem: item)],
                    browserViewModel: browserViewModel,
                    sourcePlaylistID: nil,
                    onRequestCreatePlaylist: onRequestCreatePlaylist,
                    onRequestLibraryContinuation: onRequestLibraryContinuation,
                    openArtist: openArtist,
                    artistTargetsOverride: item.artistTapTargets,
                    // Spotify exposes no Web API endpoint to remove a queue
                    // item, so do not add a misleading Remove from Queue action;
                    // Add to Queue is also meaningless for an existing row.
                    copyableURI: item.uri
                ))
            }
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
    /// Shared creation prompt owned by the browser shell for non-playlist
    /// surfaces. Playlist detail retains its inline prompt for now.
    let onRequestCreatePlaylist: (([TrackRowViewModel]) -> Void)?
    /// Queue orchestration owned by the browser shell and shared by every track
    /// surface's context menu.
    let onRequestLibraryContinuation: ((TrackRowViewModel) -> Void)?
    @EnvironmentObject private var lyricsOverlay: LyricsOverlayController

    @Binding var pendingPlaylistListScrollRestoreID: String?
    @Binding var detailLastVisibleTrackID: String?

    let currentPlaybackURI: String?
    let isCurrentlyPlaying: Bool
    let hasPlaybackDevice: Bool

    init(
        viewModel: PlaylistBrowserViewModel,
        playbackViewModel: PlaybackSessionViewModel,
        queueViewModel: QueueViewModel,
        pendingPlaylistListScrollRestoreID: Binding<String?>,
        detailLastVisibleTrackID: Binding<String?>,
        currentPlaybackURI: String?,
        isCurrentlyPlaying: Bool,
        hasPlaybackDevice: Bool,
        onRequestCreatePlaylist: (([TrackRowViewModel]) -> Void)? = nil,
        onRequestLibraryContinuation: ((TrackRowViewModel) -> Void)? = nil
    ) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        _playbackViewModel = ObservedObject(wrappedValue: playbackViewModel)
        _queueViewModel = ObservedObject(wrappedValue: queueViewModel)
        self.onRequestCreatePlaylist = onRequestCreatePlaylist
        self.onRequestLibraryContinuation = onRequestLibraryContinuation
        _pendingPlaylistListScrollRestoreID = pendingPlaylistListScrollRestoreID
        _detailLastVisibleTrackID = detailLastVisibleTrackID
        self.currentPlaybackURI = currentPlaybackURI
        self.isCurrentlyPlaying = isCurrentlyPlaying
        self.hasPlaybackDevice = hasPlaybackDevice
    }

    var body: some View {
        VStack(spacing: 0) {
            switch viewModel.detailState {
            case .loading:
                ProgressView(SpotiglassL10n.string("browser.loadingDetail"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .loaded(content), let .refreshing(content), let .staleCache(content, _):
                Group {
                    if lyricsOverlay.isPresented {
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityHidden(true)
                    } else {
                        switch content {
                        case .home:
                            HomeView(
                                viewModel: viewModel,
                                playbackViewModel: playbackViewModel,
                                queueViewModel: queueViewModel,
                                currentPlaybackURI: currentPlaybackURI,
                                isPlaying: isCurrentlyPlaying,
                                hasPlaybackDevice: hasPlaybackDevice,
                                onRequestCreatePlaylist: onRequestCreatePlaylist,
                                onRequestLibraryContinuation: onRequestLibraryContinuation
                            )
                        case .search:
                            CatalogSearchView(
                                viewModel: viewModel,
                                searchViewModel: viewModel.catalogSearch,
                                playbackViewModel: playbackViewModel,
                                queueViewModel: queueViewModel,
                                currentPlaybackURI: currentPlaybackURI,
                                isPlaying: isCurrentlyPlaying,
                                hasPlaybackDevice: hasPlaybackDevice,
                                onRequestCreatePlaylist: onRequestCreatePlaylist,
                                onRequestLibraryContinuation: onRequestLibraryContinuation
                            )
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
                                },
                                onRequestLibraryContinuation: onRequestLibraryContinuation,
                                browserViewModel: viewModel
                            )
                        case let .artist(detail):
                            ArtistDetailContent(
                                detail: detail,
                                browserViewModel: viewModel,
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
                                },
                                onRequestCreatePlaylist: onRequestCreatePlaylist,
                                onRequestLibraryContinuation: onRequestLibraryContinuation
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
                .overlay(alignment: .bottom) {
                    if let toast = viewModel.trackMutationToast {
                        Text(toast)
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, SpotiglassDesign.spacingM)
                            .padding(.vertical, SpotiglassDesign.spacingS)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.bottom, SpotiglassDesign.spacingL)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .task(id: toast) {
                                try? await Task.sleep(nanoseconds: 2_400_000_000)
                                if viewModel.trackMutationToast == toast {
                                    viewModel.trackMutationToast = nil
                                }
                            }
                    }
                }
            case let .empty(message):
                EmptyStateView(title: SpotiglassL10n.string("browser.noTracks.title"), message: message)
            case let .error(error):
                if let locked = error.lockedPlaylist {
                    FollowedPlaylistLockedView(info: locked, playbackViewModel: playbackViewModel)
                } else {
                    ErrorStateView(error: error)
                }
            }
        }
    }
}
