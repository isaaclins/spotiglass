import AppKit
import SwiftUI

enum PlaylistDetailHeaderPinning {
    static func item(for playlist: PlaylistRowViewModel) -> PinnedItem {
        if playlist.id == SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID {
            return .likedSongs(ownerDisplay: playlist.owner, artworkURL: playlist.artworkURL)
        }
        if playlist.isAlbumDetail {
            return .album(
                SpotifyAlbum(
                    id: playlist.id,
                    name: playlist.title,
                    artists: playlist.owner.isEmpty ? [] : [playlist.owner],
                    imageURL: playlist.artworkURL,
                    uri: "spotify:album:\(playlist.id)"
                )
            )
        }
        return .playlist(
            SpotifyPlaylistSummary(
                id: playlist.id,
                name: playlist.title,
                ownerID: playlist.ownerID,
                ownerName: playlist.owner,
                imageURL: playlist.artworkURL,
                trackCount: playlist.trackCount,
                snapshotID: playlist.snapshotID
            )
        )
    }

    static func supportsPinning(_ playlist: PlaylistRowViewModel) -> Bool {
        playlist.id != SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID
    }
}

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
    /// Starts a continuation from the selected row through the browser's queue
    /// orchestration.
    var onRequestLibraryContinuation: ((TrackRowViewModel) -> Void)? = nil
    /// View-model passed in so the row context-menu can call the high-level
    /// mutation helpers (`addRowsToPlaylist`, `favoriteRows`, etc.) and so the
    /// track table can bind `List` selection to `selectedDetailTrackIDs`.
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
        PlaylistDetailHeaderPinning.item(for: detail.playlist)
    }

    private var isHeaderPinned: Bool {
        pinnedStore.isPinned(id: headerPinnedItem.id)
    }

    private var supportsHeaderPinning: Bool {
        PlaylistDetailHeaderPinning.supportsPinning(detail.playlist)
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
                TrackListView(
                    tracks: detail.tracks,
                    selection: $browserViewModel.selectedDetailTrackIDs,
                    rowBuilder: { track in
                        TrackListRow(
                            trackNumber: track.listPosition,
                            track: track,
                            playURI: playURI,
                            togglePlayPause: togglePlayPause,
                            isCurrent: track.playableURI != nil && track.playableURI == currentPlaybackURI,
                            isPlaying: isPlaying,
                            openArtist: openArtist,
                            tracksSurfaceID: tracksSurfaceKey,
                            isSelected: browserViewModel.selectedDetailTrackIDs.contains(track.id),
                            drawsRowHighlights: false,
                            isKeyboardFocusable: false,
                            trackOpsMenuItems: {
                                AnyView(TrackOpsMenuItems(
                                    targets: browserViewModel.effectiveTrackTargets(forRowID: track.id),
                                    browserViewModel: browserViewModel,
                                    sourcePlaylistID: detail.playlist.isAlbumDetail ? nil : detail.playlist.id,
                                    onRequestCreatePlaylist: { rows in
                                        newPlaylistInitialRows = rows
                                        newPlaylistName = ""
                                        isPromptingNewPlaylist = true
                                    },
                                    onRequestLibraryContinuation: onRequestLibraryContinuation,
                                    openArtist: { target in
                                        if let id = target.id { openArtist(id) }
                                    },
                                    addToQueue: addToQueue,
                                    hasPlaybackDevice: hasPlaybackDevice,
                                    copyableURI: track.playableURI
                                ))
                            }
                        )
                    },
                    pendingScrollRestoreTrackID: $pendingScrollRestoreTrackID,
                    onFirstVisibleTrackChanged: onTrackEnteredViewportApproximation,
                    playSelection: { selectedIDs in
                        // Play the first selected row in list order, so a
                        // multi-row selection has a defined result.
                        guard let track = detail.tracks.first(where: { selectedIDs.contains($0.id) }),
                            let uri = track.playableURI
                        else { return }
                        playURI(uri)
                    }
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
            // Two catalog keys with a real plural rule. The old literal passed
            // an English "s" as a format argument, which Spanish rendered as
            // the non-word "canciónes" (#151).
            Text(newPlaylistInitialRows.isEmpty
                 ? SpotiglassL10n.string("playlist.detail.newPlaylist.empty")
                 : SpotiglassL10n.format(
                     "playlist.detail.newPlaylist.withTracks",
                     Int64(newPlaylistInitialRows.count)
                   ))
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
                    LikedSongsArtwork(
                        size: SpotiglassDesign.detailHeaderArtworkSize,
                        isEmphasized: true
                    )
                        .overlay(alignment: .topTrailing) {
                            if isHeaderPinned {
                                PinnedBadge(scale: .prominent)
                            }
                        }
                } else {
                    ArtworkView(url: detail.playlist.artworkURL, size: SpotiglassDesign.detailHeaderArtworkSize)
                        .overlay(alignment: .topTrailing) {
                            if isHeaderPinned {
                                PinnedBadge(scale: .prominent)
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

/// Actions owned by the shared track context menu. Play remains on each
/// surface because its label and playback orchestration are surface-specific.
enum TrackOpsMenuAction: Hashable {
    case openArtist
    case addToQueue
    case pin
    case unpin
    case copyURI
}

/// Spotify track-ops menu rendered inside a track-row context menu.
/// The caller supplies the targets so playlist selection, catalog results, and
/// queue occurrences can all share this one action list. It stays outside the
/// cell so the row body type-checks fast and playlist enumeration runs only
/// when the menu is actually opened.
struct TrackOpsMenuItems: View {
    /// Rows supplied by the surface that opened the menu. Playlist detail may
    /// provide its active selection; other surfaces pass the row directly.
    let targets: [TrackRowViewModel]
    @ObservedObject var browserViewModel: PlaylistBrowserViewModel
    /// The playlist the targets came from, when there is one. Without a source
    /// there is no meaningful removal operation, so the Move menu is omitted.
    let sourcePlaylistID: String?
    /// The playlist detail supplies its inline creation prompt. Other surfaces
    /// can provide the same callback from their shared browser host.
    let onRequestCreatePlaylist: (([TrackRowViewModel]) -> Void)?
    /// Starts a library continuation using the row as its seed. The browser
    /// host injects queue orchestration so this menu stays reusable.
    let onRequestLibraryContinuation: ((TrackRowViewModel) -> Void)?
    /// Opens an artist from the shared context-menu submenu.
    let openArtist: ((ArtistTapTarget) -> Void)?
    /// Queue occurrences retain artist names even when Spotify omitted an ID.
    /// Other surfaces derive this list from their row's artist references.
    let artistTargetsOverride: [ArtistTapTarget]?
    /// Adds all playable target rows to the queue. Queue rows leave this nil
    /// because they are already in the queue.
    let addToQueue: ((String) async -> Void)?
    let hasPlaybackDevice: Bool
    /// A non-nil URI enables Copy Spotify URI on surfaces that have one.
    let copyableURI: String?

    @EnvironmentObject private var pinnedStore: PinnedItemsStore

    init(
        targets: [TrackRowViewModel],
        browserViewModel: PlaylistBrowserViewModel,
        sourcePlaylistID: String? = nil,
        onRequestCreatePlaylist: (([TrackRowViewModel]) -> Void)? = nil,
        onRequestLibraryContinuation: ((TrackRowViewModel) -> Void)? = nil,
        openArtist: ((ArtistTapTarget) -> Void)? = nil,
        artistTargetsOverride: [ArtistTapTarget]? = nil,
        addToQueue: ((String) async -> Void)? = nil,
        hasPlaybackDevice: Bool = false,
        copyableURI: String? = nil
    ) {
        self.targets = targets
        self.browserViewModel = browserViewModel
        self.sourcePlaylistID = sourcePlaylistID
        self.onRequestCreatePlaylist = onRequestCreatePlaylist
        self.onRequestLibraryContinuation = onRequestLibraryContinuation
        self.openArtist = openArtist
        self.artistTargetsOverride = artistTargetsOverride
        self.addToQueue = addToQueue
        self.hasPlaybackDevice = hasPlaybackDevice
        self.copyableURI = copyableURI
    }

    /// The action set is intentionally inspectable so every track surface can
    /// test the shared contract without depending on AppKit's context-menu host.
    var menuActionKinds: Set<TrackOpsMenuAction> {
        var actions: Set<TrackOpsMenuAction> = []
        if openArtist != nil, !artistTargets.isEmpty {
            actions.insert(.openArtist)
        }
        if addToQueue != nil {
            actions.insert(.addToQueue)
        }
        switch pinState {
        case .pin:
            actions.insert(.pin)
        case .unpin:
            actions.insert(.unpin)
        case .unavailable:
            break
        }
        if SpotifyPlayableURI.canonical(copyableURI) != nil {
            actions.insert(.copyURI)
        }
        return actions
    }

    private var sourcePlaylistForMove: String? {
        guard let sourcePlaylistID, !sourcePlaylistID.isEmpty else { return nil }
        return sourcePlaylistID
    }

    private var artistTargets: [ArtistTapTarget] {
        var seen: Set<String> = []
        let supplied = artistTargetsOverride ?? targets.flatMap { row in
            row.artistRefs.map { ArtistTapTarget(id: $0.id, name: $0.name) }
        }
        return supplied.filter { seen.insert($0.stableID).inserted }
    }

    private var pinnableItems: [PinnedItem] {
        var seen: Set<String> = []
        return targets.compactMap { $0.pinnedTrackItem() }
            .filter { seen.insert($0.id).inserted }
    }

    private var pinState: TrackSelectionPinState {
        PlaylistBrowserView.trackSelectionPinState(
            for: pinnableItems,
            isPinned: { pinnedStore.isPinned(id: $0) }
        )
    }

    private var likedSongsTargets: [TrackRowViewModel] {
        browserViewModel.likedSongsMutationRows(for: targets)
    }

    private var likedSongsState: TrackSelectionLikedState {
        guard !likedSongsTargets.isEmpty else { return .unavailable }
        if sourcePlaylistID == SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID {
            // Every catalog track displayed by Liked Songs is saved already;
            // do not turn a locally-known fact into a `/contains` request.
            return PlaylistBrowserView.trackSelectionLikedState(
                for: likedSongsTargets,
                isSaved: { _ in true }
            )
        }
        let ids = browserViewModel.catalogTrackIDs(for: likedSongsTargets)
        guard ids.count == likedSongsTargets.count,
              ids.allSatisfy({ browserViewModel.savedTrackState(for: $0) != nil })
        else { return .unavailable }
        return PlaylistBrowserView.trackSelectionLikedState(
            for: likedSongsTargets,
            isSaved: { browserViewModel.savedTrackState(for: $0) ?? false }
        )
    }

    private var savedTrackLookupIDs: [String] {
        guard sourcePlaylistID != SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID else { return [] }
        return browserViewModel.catalogTrackIDs(for: likedSongsTargets)
    }

    var body: some View {
        menuContent
            .task(id: savedTrackLookupIDs) {
                guard sourcePlaylistID != SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID else { return }
                await browserViewModel.loadSavedTrackStates(for: likedSongsTargets)
            }
    }

    @ViewBuilder
    private var menuContent: some View {
        let playlistTargets = browserViewModel.playlistMutationRows(for: targets)
        let likedSongsLabel = SpotiglassL10n.format(
            "playlist.mutation.trackLabel",
            Int64(likedSongsTargets.count)
        )
        let destinations = browserViewModel.userOwnedPlaylistsForMenu(
            excludingPlaylistID: sourcePlaylistID
        )

        if menuActionKinds.contains(.openArtist), let openArtist {
            Menu(SpotiglassL10n.string("browser.track.openArtist")) {
                ForEach(artistTargets) { target in
                    Button(target.name) {
                        openArtist(target)
                    }
                }
            }
        }

        if menuActionKinds.contains(.addToQueue), let addToQueue {
            let playableURIs = targets.compactMap { SpotifyPlayableURI.canonical($0.playableURI) }
            Button(SpotiglassL10n.string("browser.addToQueue")) {
                Task {
                    for uri in playableURIs {
                        await addToQueue(uri)
                    }
                }
            }
            .disabled(!hasPlaybackDevice || playableURIs.isEmpty)
        }

        switch pinState {
        case .pin:
            Button(SpotiglassL10n.string("browser.pin")) {
                for item in pinnableItems {
                    pinnedStore.pin(item)
                }
            }
        case .unpin:
            Button(SpotiglassL10n.string("browser.unpin")) {
                for item in pinnableItems {
                    pinnedStore.unpin(id: item.id)
                }
            }
        case .unavailable:
            EmptyView()
        }

        if menuActionKinds.contains(.copyURI),
           let uri = SpotifyPlayableURI.canonical(copyableURI) {
            Button(SpotiglassL10n.string("queue.copyURI")) {
                copySpotifyURI(uri)
            }
        }

        Menu(SpotiglassL10n.string("Add to playlist")) {
            if let onRequestCreatePlaylist {
                Button(SpotiglassL10n.string("playlist.detail.newPlaylist.menuItem")) {
                    onRequestCreatePlaylist(playlistTargets)
                }
                if !destinations.isEmpty { Divider() }
            }
            ForEach(destinations, id: \.id) { dest in
                Button(dest.name) {
                    Task {
                        await browserViewModel.addRowsToPlaylist(
                            playlistTargets,
                            playlistID: dest.id,
                            playlistName: dest.name
                        )
                    }
                }
            }
        }
        .disabled(playlistTargets.isEmpty)

        if let sourcePlaylistID = sourcePlaylistForMove {
            Menu(SpotiglassL10n.string("Move to playlist")) {
                ForEach(destinations, id: \.id) { dest in
                    Button(dest.name) {
                        Task {
                            await browserViewModel.moveRowsBetweenPlaylists(
                                playlistTargets,
                                from: sourcePlaylistID,
                                to: dest.id,
                                destinationName: dest.name
                            )
                        }
                    }
                }
            }
            .disabled(playlistTargets.isEmpty || destinations.isEmpty)
        }

        let likedSongsState = likedSongsState
        Button(
            SpotiglassL10n.format(
                likedSongsState == .remove
                    ? "playlist.detail.likedSongs.remove"
                    : "playlist.detail.likedSongs.add",
                likedSongsLabel
            )
        ) {
            Task {
                switch likedSongsState {
                case .add:
                    await browserViewModel.favoriteRows(likedSongsTargets)
                case .remove:
                    await browserViewModel.unfavoriteRows(likedSongsTargets)
                case .unavailable:
                    break
                }
            }
        }
        .disabled(likedSongsTargets.isEmpty || likedSongsState == .unavailable)

        if let seed = targets.first(where: { $0.spotifyTrackForPinning() != nil }),
           let onRequestLibraryContinuation {
            Divider()
            Button(SpotiglassL10n.string("library.continuation.menu")) {
                onRequestLibraryContinuation(seed)
            }
        }
    }

    private func copySpotifyURI(_ uri: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(uri, forType: .string)
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
