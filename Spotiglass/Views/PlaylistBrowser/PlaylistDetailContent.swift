import SwiftUI

struct PlaylistDetailContent: View {
    let detail: PlaylistDetailViewModel
    var currentUserSpotifyID: String?
    @Binding var pendingScrollRestoreTrackID: String?
    let onTrackEnteredViewportApproximation: (String) -> Void
    let playURI: (String) -> Void
    let currentPlaybackURI: String?
    let isPlaying: Bool
    let togglePlayPause: () -> Void
    let hasPlaybackDevice: Bool
    let addToQueue: (String) async -> Void
    let openArtist: (String) -> Void
    /// View-model passed in so the row context-menu can call the high-level
    /// mutation helpers (`addRowsToPlaylist`, `favoriteRows`, etc.) and observe
    /// `selectedDetailTrackIDs` for the shift-click multi-select highlight.
    @ObservedObject var browserViewModel: PlaylistBrowserViewModel

    @EnvironmentObject private var pinnedStore: PinnedItemsStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var isPromptingNewPlaylist = false
    @State private var newPlaylistName = ""
    @State private var newPlaylistInitialRows: [TrackRowViewModel] = []
    @State private var isEditingPlaylistName = false
    @State private var editingPlaylistID: String?
    @State private var editedPlaylistName = ""
    @FocusState private var isPlaylistNameFocused: Bool

    private var tracksSurfaceKey: String { "pl:\(detail.playlist.id)" }

    private var headerPinnedItem: PinnedItem {
        if detail.playlist.id == SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID {
            .likedSongs(ownerDisplay: detail.playlist.owner, artworkURL: detail.playlist.artworkURL)
        } else {
            .playlist(
                SpotifyPlaylistSummary(
                    id: detail.playlist.id,
                    name: detail.playlist.title,
                    ownerID: detail.playlist.ownerID,
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

    private var canRenamePlaylist: Bool {
        guard detail.playlist.id != SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID,
              let currentUserID = currentUserSpotifyID,
              !currentUserID.isEmpty
        else { return false }
        return detail.playlist.ownerID == currentUserID
    }

    private var isEditingDisplayedPlaylistName: Bool {
        guard isEditingPlaylistName,
              let editingPlaylistID
        else { return false }
        return editingPlaylistID == detail.playlist.id
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBlock

            Divider()

            if detail.tracks.isEmpty {
                EmptyStateView(title: SpotiglassL10n.string("browser.noTracks.title"), message: SpotiglassL10n.string("browser.noTracks.emptyPlaylist"))
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
                            isSelected: browserViewModel.selectedDetailTrackIDs.contains(track.id),
                            onShiftSelect: { rowID in
                                browserViewModel.extendSelection(toRowID: rowID)
                            },
                            onPrimarySelect: { rowID in
                                browserViewModel.setPrimarySelection(trackID: rowID)
                            },
                            trackOpsMenuItems: {
                                AnyView(TrackOpsMenuItems(
                                    rowID: track.id,
                                    browserViewModel: browserViewModel,
                                    currentPlaylistID: detail.playlist.id,
                                    onRequestCreatePlaylist: { rows in
                                        newPlaylistInitialRows = rows
                                        newPlaylistName = ""
                                        isPromptingNewPlaylist = true
                                    }
                                ))
                            }
                        )
                    },
                    pendingScrollRestoreTrackID: $pendingScrollRestoreTrackID,
                    onFirstVisibleTrackChanged: onTrackEnteredViewportApproximation
                )
            }
        }
        .alert(SpotiglassL10n.string("playlist.detail.newPlaylist.title"), isPresented: $isPromptingNewPlaylist) {
            TextField(SpotiglassL10n.string("playlist.detail.newPlaylist.field"), text: $newPlaylistName)
            Button(SpotiglassL10n.string("playlist.detail.newPlaylist.cancel"), role: .cancel) {
                newPlaylistInitialRows = []
                newPlaylistName = ""
            }
            Button(SpotiglassL10n.string("playlist.detail.newPlaylist.create")) {
                let rows = newPlaylistInitialRows
                let name = newPlaylistName
                newPlaylistInitialRows = []
                newPlaylistName = ""
                Task { await browserViewModel.createPlaylistWithRows(name: name, rows: rows) }
            }
            .disabled(newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: {
            Text(newPlaylistInitialRows.isEmpty
                 ? "Create an empty playlist in your Spotify library."
                 : "Create a new playlist with \(newPlaylistInitialRows.count) track\(newPlaylistInitialRows.count == 1 ? "" : "s") added.")
        }
        .onChange(of: detail.playlist.id) { _, _ in
            cancelPlaylistNameEditing()
        }
        // Cancel on focus loss instead of committing on blur. This avoids
        // saving an unfinished name after focus moves to another surface.
        .onChange(of: isPlaylistNameFocused) { _, isFocused in
            guard !isFocused, isEditingPlaylistName else { return }
            cancelPlaylistNameEditing()
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
                                .strokeBorder(SpotiglassDesign.artworkBorderColor(colorScheme: colorScheme), lineWidth: 1)
                        }
                        .overlay(alignment: .topTrailing) {
                            if isHeaderPinned {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(SpotiglassDesign.mediaBadgeForegroundColor(colorScheme: colorScheme))
                                    .padding(5)
                                    .background(
                                        Circle().fill(SpotiglassDesign.mediaBadgeBackgroundColor(colorScheme: colorScheme))
                                    )
                                    .padding(4)
                                    .help(SpotiglassL10n.string("browser.pinned"))
                                    .accessibilityLabel(SpotiglassL10n.string("browser.pinned"))
                            }
                        }
                } else {
                    ArtworkView(url: detail.playlist.artworkURL, size: 104)
                        .overlay(alignment: .topTrailing) {
                            if isHeaderPinned {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(SpotiglassDesign.mediaBadgeForegroundColor(colorScheme: colorScheme))
                                    .padding(5)
                                    .background(
                                        Circle().fill(SpotiglassDesign.mediaBadgeBackgroundColor(colorScheme: colorScheme))
                                    )
                                    .padding(4)
                                    .help(SpotiglassL10n.string("browser.pinned"))
                                    .accessibilityLabel(SpotiglassL10n.string("browser.pinned"))
                            }
                        }
                }
            }

            VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
                playlistTitle

                Text(detail.playlist.ownerTracksLine(currentUserID: currentUserSpotifyID))
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
            pinnedStore: pinnedStore,
            canRenamePlaylist: canRenamePlaylist,
            onEditPlaylistName: beginPlaylistNameEditing
        ))
    }

    @ViewBuilder
    private var playlistTitle: some View {
        if isEditingDisplayedPlaylistName {
            TextField("", text: $editedPlaylistName)
                .font(.largeTitle.weight(.semibold))
                .textFieldStyle(.plain)
                .lineLimit(2)
                .focused($isPlaylistNameFocused)
                .onSubmit(commitPlaylistName)
                .onExitCommand(perform: cancelPlaylistNameEditing)
                .onAppear { isPlaylistNameFocused = true }
        } else {
            Text(detail.playlist.title)
                .font(.largeTitle.weight(.semibold))
                .lineLimit(2)
                .onTapGesture(count: 2, perform: beginPlaylistNameEditing)
        }
    }

    private func beginPlaylistNameEditing() {
        guard canRenamePlaylist else { return }
        editingPlaylistID = detail.playlist.id
        editedPlaylistName = detail.playlist.title
        isEditingPlaylistName = true
    }

    private func commitPlaylistName() {
        guard isEditingPlaylistName,
              let capturedPlaylistID = PlaylistRenameEditingPolicy.commitTarget(
                  editingPlaylistID: editingPlaylistID,
                  displayedPlaylistID: detail.playlist.id
              )
        else {
            cancelPlaylistNameEditing()
            return
        }
        let name = editedPlaylistName
        isEditingPlaylistName = false
        editingPlaylistID = nil
        isPlaylistNameFocused = false
        Task {
            await browserViewModel.renamePlaylist(id: capturedPlaylistID, name: name)
        }
    }

    private func cancelPlaylistNameEditing() {
        isEditingPlaylistName = false
        editingPlaylistID = nil
        isPlaylistNameFocused = false
        editedPlaylistName = ""
    }
}

/// Validates that a rename still targets the playlist whose editor was opened.
/// SwiftUI can retain the editor state while the displayed playlist changes.
enum PlaylistRenameEditingPolicy {
    static func commitTarget(editingPlaylistID: String?, displayedPlaylistID: String) -> String? {
        guard let editingPlaylistID,
              editingPlaylistID == displayedPlaylistID
        else { return nil }
        return editingPlaylistID
    }

    static func commitTarget(
        editingPlaylistID: String?,
        rowID: String,
        visiblePlaylistIDs: [String]
    ) -> String? {
        guard let target = commitTarget(
            editingPlaylistID: editingPlaylistID,
            displayedPlaylistID: rowID
        ), visiblePlaylistIDs.contains(target)
        else { return nil }
        return target
    }
}

/// Spotify track-ops submenu rendered inside `TrackListRow.contextMenu`.
/// Targets either the active shift-click selection or the row alone — kept
/// outside the cell so the row body type-checks fast and the menu's expensive
/// playlist enumeration runs only when the menu is actually opened.
struct TrackOpsMenuItems: View {
    let rowID: String
    @ObservedObject var browserViewModel: PlaylistBrowserViewModel
    /// Playlist ID currently shown; used to mark "Move" as relative to "this"
    /// playlist and to filter the source out of "Move to…" destinations.
    let currentPlaylistID: String
    let onRequestCreatePlaylist: ([TrackRowViewModel]) -> Void

    var body: some View {
        let targets = browserViewModel.effectiveTrackTargets(forRowID: rowID)
        let label = targets.count > 1 ? "\(targets.count) tracks" : "track"
        let destinations = browserViewModel.userOwnedPlaylistsForMenu(
            excludingPlaylistID: currentPlaylistID
        )

        Menu("Add to playlist") {
            Button(SpotiglassL10n.string("playlist.detail.newPlaylist.menuItem")) {
                onRequestCreatePlaylist(targets)
            }
            if !destinations.isEmpty { Divider() }
            ForEach(destinations, id: \.id) { dest in
                Button(dest.name) {
                    Task {
                        await browserViewModel.addRowsToPlaylist(
                            targets,
                            playlistID: dest.id,
                            playlistName: dest.name
                        )
                    }
                }
            }
        }
        .disabled(targets.isEmpty)

        Menu("Move to playlist") {
            ForEach(destinations, id: \.id) { dest in
                Button(dest.name) {
                    Task {
                        await browserViewModel.moveRowsBetweenPlaylists(
                            targets,
                            from: currentPlaylistID,
                            to: dest.id,
                            destinationName: dest.name
                        )
                    }
                }
            }
        }
        .disabled(targets.isEmpty || destinations.isEmpty)

        Button(SpotiglassL10n.format("playlist.detail.likedSongs.add", label)) {
            Task { await browserViewModel.favoriteRows(targets) }
        }
        .disabled(targets.isEmpty)

        Button(SpotiglassL10n.format("playlist.detail.likedSongs.remove", label)) {
            Task { await browserViewModel.unfavoriteRows(targets) }
        }
        .disabled(targets.isEmpty)
    }
}

struct LibraryHeaderPinningModifier: ViewModifier {
    let supportsHeaderPinning: Bool
    let headerPinnedItem: PinnedItem
    let tracksSurfaceKey: String
    let isHeaderPinned: Bool
    let pinnedStore: PinnedItemsStore
    let canRenamePlaylist: Bool
    let onEditPlaylistName: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if supportsHeaderPinning {
            content
                .draggable(PinnedItemTransfer(item: headerPinnedItem)) {
                    PinnedItemDragPill(item: headerPinnedItem)
                }
                .contextMenu {
                    if canRenamePlaylist {
                        Button(SpotiglassL10n.string("browser.editPlaylistName")) {
                            onEditPlaylistName()
                        }
                        Divider()
                    }
                    if isHeaderPinned {
                        Button(SpotiglassL10n.string("browser.unpin")) {
                            pinnedStore.unpin(id: headerPinnedItem.id)
                        }
                    } else {
                        Button(SpotiglassL10n.string("browser.pin")) {
                            pinnedStore.pin(headerPinnedItem)
                        }
                    }
                }
        } else {
            content
        }
    }
}
