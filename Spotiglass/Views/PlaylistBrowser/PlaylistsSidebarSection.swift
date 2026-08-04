import SwiftUI

struct PlaylistsSidebarSectionHeader: View {
    let playlistState: BrowsingLoadState<[PlaylistRowViewModel]>

    var body: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
            Text(SpotiglassL10n.string("browser.playlists"))
                .font(.title3.weight(.semibold))
            switch playlistState {
            case .staleCache:
                Text(SpotiglassL10n.string("browser.cachedData"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .refreshing:
                Text(SpotiglassL10n.string("browser.refreshing"))
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
    @State private var editingPlaylistID: String?
    @State private var editedPlaylistName = ""
    @FocusState private var isPlaylistNameFocused: Bool
    let playlistSummaryFromRow: (PlaylistRowViewModel) -> SpotifyPlaylistSummary

    private var isCurrentlyPlaying: Bool {
        if case .playing = playbackViewModel.connectionState { return true }
        return false
    }

    private var visiblePlaylistIDs: [String] {
        playlistState.currentValue?.map(\.id) ?? []
    }

    var body: some View {
        Group {
            likedSongsSidebarRow
            switch playlistState {
            case .loading:
                ProgressView(SpotiglassL10n.string("browser.loadingPlaylists"))
            case let .loaded(playlists), let .refreshing(playlists), let .staleCache(playlists, _):
                ForEach(playlists) { playlist in
                    playlistSidebarRow(playlist: playlist)
                }
            case let .empty(message):
                EmptyStateView(title: SpotiglassL10n.string("browser.noPlaylists.title"), message: message)
            case let .error(error):
                ErrorStateView(error: error)
            }
        }
        .onChange(of: viewModel.sidebarSelection) { _, newSelection in
            guard let editingPlaylistID,
                  newSelection != .playlist(editingPlaylistID)
            else { return }
            cancelPlaylistNameEditing()
        }
        .onChange(of: visiblePlaylistIDs) { _, playlistIDs in
            guard let editingPlaylistID,
                  playlistIDs.contains(editingPlaylistID) == false
            else { return }
            cancelPlaylistNameEditing()
        }
        // Cancel on focus loss instead of committing on blur. This avoids
        // saving an unfinished name after focus moves to another surface.
        .onChange(of: isPlaylistNameFocused) { _, isFocused in
            guard !isFocused, editingPlaylistID != nil else { return }
            cancelPlaylistNameEditing()
        }
    }

    @ViewBuilder
    private var likedSongsSidebarRow: some View {
        PlaylistListRow(
            playlist: likedSongsStubRow,
            currentUserSpotifyID: viewModel.currentUserSpotifyID,
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
            currentUserSpotifyID: viewModel.currentUserSpotifyID,
            isActive: playlist.id == playbackViewModel.activePlaylistID,
            isPlaying: isCurrentlyPlaying,
            isListSelected: viewModel.sidebarSelection == .playlist(playlist.id),
            isPinned: pinned,
            titleOverride: editingPlaylistID == playlist.id
                ? AnyView(playlistRenameEditor(playlist: playlist))
                : nil
        )
        .tag(SidebarSelection.playlist(playlist.id))
        .id(playlist.id)
        .draggable(PinnedItemTransfer(item: .playlist(summary))) {
            PinnedItemDragPill(item: .playlist(summary))
        }
        .contextMenu {
            if canRenamePlaylist(summary) {
                Button(SpotiglassL10n.string("browser.editPlaylistName")) {
                    beginPlaylistNameEditing(for: playlist)
                }
                Divider()
            }
            if pinned {
                Button(SpotiglassL10n.string("browser.unpin.short")) {
                    pinnedStore.unpin(id: PinnedItem.id(forKind: .playlist, spotifyID: playlist.id))
                }
            } else {
                Button(SpotiglassL10n.string("browser.pin")) {
                    pinnedStore.pin(.playlist(summary))
                }
            }
        }
    }

    private func canRenamePlaylist(_ summary: SpotifyPlaylistSummary) -> Bool {
        guard let currentUserID = viewModel.currentUserSpotifyID,
              !currentUserID.isEmpty
        else { return false }
        return summary.ownerID == currentUserID
    }

    private func beginPlaylistNameEditing(for playlist: PlaylistRowViewModel) {
        guard canRenamePlaylist(playlistSummaryFromRow(playlist)) else { return }
        editingPlaylistID = playlist.id
        editedPlaylistName = playlist.title
    }

    private func playlistRenameEditor(playlist: PlaylistRowViewModel) -> some View {
        TextField("", text: $editedPlaylistName)
            .font(.headline)
            .textFieldStyle(.plain)
            .focused($isPlaylistNameFocused)
            .onSubmit { commitPlaylistName(for: playlist.id) }
            .onExitCommand(perform: cancelPlaylistNameEditing)
            .onAppear { isPlaylistNameFocused = true }
    }

    private func commitPlaylistName(for playlistID: String) {
        guard let capturedPlaylistID = PlaylistRenameEditingPolicy.commitTarget(
            editingPlaylistID: editingPlaylistID,
            rowID: playlistID,
            visiblePlaylistIDs: visiblePlaylistIDs
        )
        else {
            cancelPlaylistNameEditing()
            return
        }
        let name = editedPlaylistName
        editingPlaylistID = nil
        isPlaylistNameFocused = false
        Task {
            await viewModel.renamePlaylist(id: capturedPlaylistID, name: name)
        }
    }

    private func cancelPlaylistNameEditing() {
        editingPlaylistID = nil
        isPlaylistNameFocused = false
        editedPlaylistName = ""
    }
}
