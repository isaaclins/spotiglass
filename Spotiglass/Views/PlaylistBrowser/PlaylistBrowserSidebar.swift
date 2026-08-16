import SwiftUI

struct PlaylistBrowserSidebar: View {
    @ObservedObject var viewModel: PlaylistBrowserViewModel
    @ObservedObject var playbackViewModel: PlaybackSessionViewModel

    let libraryRows: [LibrarySidebarRow]
    /// Set when the account lookup behind the pinned list failed, so the empty
    /// Library section can say so and offer a retry instead of looking like an
    /// account with no pins (#133).
    var pinnedBindingFailed: Bool = false
    var retryPinnedBinding: (() -> Void)? = nil

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
                // Kept out of the Library section (and out of `LibrarySidebarOrder`)
                // so it always sits at the very top and never joins the
                // drag-to-reorder group.
                Section {
                    Label(SpotiglassL10n.string("browser.search"), systemImage: "magnifyingglass")
                        .tag(SidebarSelection.search)
                }
                Section {
                    ForEach(libraryRows) { row in
                        libraryRow(row)
                            .tag(row.sidebarSelectionTag)
                    }
                    .onMove { source, destination in
                        moveLibraryRows(source, destination)
                    }
                    if pinnedBindingFailed {
                        HStack(spacing: SpotiglassDesign.spacingXS) {
                            Text(SpotiglassL10n.string("browser.pinned.loadFailed"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button(SpotiglassL10n.string("browser.retry")) {
                                retryPinnedBinding?()
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
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
                if case let .staleCache(_, error) = viewModel.playlistState {
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
        case .home:
            LibraryHomeSidebarRow()
        case let .pinned(item):
            PinnedSidebarLibraryRow(item: item, isSelected: viewModel.sidebarSelection == .pinnedItem(item.id))
        }
    }
}
