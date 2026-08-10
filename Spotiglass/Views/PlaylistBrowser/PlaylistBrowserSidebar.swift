import SwiftUI

struct PlaylistBrowserSidebar: View {
    @ObservedObject var viewModel: PlaylistBrowserViewModel
    @ObservedObject var playbackViewModel: PlaybackSessionViewModel

    let libraryRows: [LibrarySidebarRow]

    let likedSongsStubRow: PlaylistRowViewModel
    let playlistSummaryFromRow: (PlaylistRowViewModel) -> SpotifyPlaylistSummary

    let onLibraryAppear: () -> Void
    let onSidebarListSelectionChange: (SidebarSelection?, SidebarSelection?) -> Void
    /// Native `List.onMove` reorder of the Library section rows.
    let moveLibraryRows: (IndexSet, Int) -> Void
    /// Drag-to-pin: a `PinnedItemTransfer` dropped anywhere on the sidebar
    /// pins the item (appended to the end of the pins group).
    let pinDroppedTransfers: ([PinnedItemTransfer]) -> Bool

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $viewModel.sidebarSelection) {
                Section {
                    ForEach(libraryRows) { row in
                        libraryRow(row)
                            .tag(row.sidebarSelectionTag)
                    }
                    .onMove { source, destination in
                        moveLibraryRows(source, destination)
                    }
                } header: {
                    Text(SpotiglassL10n.string("browser.library"))
                }
                Section {
                    PlaylistsSidebarSectionContent(
                        playlistState: viewModel.playlistState,
                        likedSongsStubRow: likedSongsStubRow,
                        viewModel: viewModel,
                        playbackViewModel: playbackViewModel,
                        playlistSummaryFromRow: playlistSummaryFromRow
                    )
                } header: {
                    PlaylistsSidebarSectionHeader(playlistState: viewModel.playlistState)
                }
            }
            .dropDestination(for: PinnedItemTransfer.self) { transfers, _ in
                pinDroppedTransfers(transfers)
            }
            .onChange(of: viewModel.sidebarSelection) { oldValue, newValue in
                onSidebarListSelectionChange(oldValue, newValue)
            }
            .onChange(of: playbackViewModel.activePlaylistID) { _, newActiveID in
                guard let newActiveID else { return }
                proxy.scrollTo(newActiveID, anchor: .center)
            }
            .onAppear {
                onLibraryAppear()
            }
            .overlay(alignment: .bottom) {
                if case .staleCache(_, let error) = viewModel.playlistState {
                    StaleCacheBanner(error: error)
                } else if case .refreshing = viewModel.playlistState {
                    ProgressView(SpotiglassL10n.string("browser.refreshingPlaylists"))
                        .controlSize(.small)
                        .padding(SpotiglassDesign.spacingS)
                        .background(.background, in: Capsule())
                        .padding(SpotiglassDesign.spacingM)
                }
            }
            .listStyle(.sidebar)
            .tint(SpotiglassDesign.controlAccent)
        }
    }

    @ViewBuilder
    private func libraryRow(_ row: LibrarySidebarRow) -> some View {
        switch row {
        case .search:
            LibrarySearchSidebarRow()
        case .home:
            LibraryHomeSidebarRow()
        case .pinned(let item):
            PinnedSidebarLibraryRow(item: item, isSelected: viewModel.sidebarSelection == .pinnedItem(item.id))
        }
    }
}
