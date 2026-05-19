import SwiftUI

struct PlaylistsSidebarSectionHeader: View {
    let playlistState: BrowsingLoadState<[PlaylistRowViewModel]>

    var body: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
            Text("browser.playlists", bundle: .main)
                .font(.title3.weight(.semibold))
            switch playlistState {
            case .staleCache:
                Text("browser.cachedData", bundle: .main)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .refreshing:
                Text("browser.refreshing", bundle: .main)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
    }
}

struct PlaylistsSidebarSectionContent: View {
    let playlistState: BrowsingLoadState<[PlaylistRowViewModel]>
    let likedSongsStubRow: PlaylistRowViewModel
    @ObservedObject var viewModel: PlaylistBrowserViewModel
    @ObservedObject var playbackViewModel: PlaybackSessionViewModel
    @EnvironmentObject private var pinnedStore: PinnedItemsStore
    let playlistSummaryFromRow: (PlaylistRowViewModel) -> SpotifyPlaylistSummary

    private var isCurrentlyPlaying: Bool {
        if case .playing = playbackViewModel.connectionState { return true }
        return false
    }

    var body: some View {
        Group {
            likedSongsSidebarRow
            switch playlistState {
            case .loading:
                ProgressView(String(localized: "browser.loadingPlaylists"))
            case let .loaded(playlists), let .refreshing(playlists), let .staleCache(playlists, _):
                ForEach(playlists) { playlist in
                    playlistSidebarRow(playlist: playlist)
                }
            case let .empty(message):
                EmptyStateView(title: String(localized: "browser.noPlaylists.title"), message: message)
            case let .error(error):
                ErrorStateView(error: error)
            }
        }
    }

    @ViewBuilder
    private var likedSongsSidebarRow: some View {
        PlaylistListRow(
            playlist: likedSongsStubRow,
            isActive: playbackViewModel.activePlaylistID == SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID,
            isPlaying: isCurrentlyPlaying,
            isListSelected: viewModel.sidebarSelection == .likedSongs,
            isPinned: false
        )
        .id(SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID)
        .tag(SidebarSelection.likedSongs)
    }

    @ViewBuilder
    private func playlistSidebarRow(playlist: PlaylistRowViewModel) -> some View {
        let pinned = pinnedStore.isPinned(spotifyID: playlist.id, kind: .playlist)
        let summary = playlistSummaryFromRow(playlist)
        PlaylistListRow(
            playlist: playlist,
            isActive: playlist.id == playbackViewModel.activePlaylistID,
            isPlaying: isCurrentlyPlaying,
            isListSelected: viewModel.sidebarSelection == .playlist(playlist.id),
            isPinned: pinned
        )
        .tag(SidebarSelection.playlist(playlist.id))
        .id(playlist.id)
        .onDrag(
            {
                PinnedItemTransfer(
                    item: .playlist(summary),
                    originScopeID: "sidebarPlaylists"
                ).itemProvider()
            },
            preview: {
                PinnedItemDragPill(item: .playlist(summary))
            }
        )
        .contextMenu {
            if pinned {
                Button(String(localized: "browser.unpin.short")) {
                    pinnedStore.unpin(id: PinnedItem.id(forKind: .playlist, spotifyID: playlist.id))
                }
            } else {
                Button(String(localized: "browser.pin")) {
                    pinnedStore.pin(.playlist(summary))
                }
            }
        }
    }
}
