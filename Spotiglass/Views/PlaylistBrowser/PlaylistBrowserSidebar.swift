import SwiftUI

struct PlaylistBrowserSidebar: View {
    @ObservedObject var viewModel: PlaylistBrowserViewModel
    @ObservedObject var playbackViewModel: PlaybackSessionViewModel

    let libraryRows: [LibrarySidebarRow]
    @Binding var libraryDropInsertionIndex: Int?
    @Binding var libraryRowFramesByToken: [String: CGRect]
    @ObservedObject var dragPreviewState: PinnedDragPreviewState

    let likedSongsStubRow: PlaylistRowViewModel
    let playlistSummaryFromRow: (PlaylistRowViewModel) -> SpotifyPlaylistSummary

    let onLibraryAppear: () -> Void
    let onSidebarListSelectionChange: (SidebarSelection?, SidebarSelection?) -> Void
    let handlePinnedTransferDrop: ([PinnedItemTransfer], Int) -> Bool
    let handleLibraryTransferDrop: ([LibrarySidebarRowTransfer], Int) -> Bool

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $viewModel.sidebarSelection) {
                Section {
                    libraryLeadingDropSlot
                    ForEach(Array(libraryRows.enumerated()), id: \.element.id) { index, row in
                        libraryRowSlot(row, at: index)
                    }
                    libraryTrailingDropSlot
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
            .onPreferenceChange(LibraryRowFramePreferenceKey.self) { libraryRowFramesByToken = $0 }
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
            .coordinateSpace(name: "libraryDropArea")
        }
    }

    @ViewBuilder
    private func libraryRowSlot(_ row: LibrarySidebarRow, at index: Int) -> some View {
        let rowSelection = row.sidebarSelectionTag
        VStack(spacing: 0) {
            if libraryDropInsertionIndex == index {
                PinnedDropSkeletonRow(item: dragPreviewState.activeItem)
            }
            switch row {
            case .home:
                LibraryHomeSidebarRow()
            case let .pinned(item):
                PinnedSidebarLibraryRow(item: item, isSelected: viewModel.sidebarSelection == .pinnedItem(item.id))
            }
        }
        .tag(rowSelection)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.sidebarSelection = rowSelection
        }
        .onDrop(
            of: LibraryPinnedItemDropDelegate.acceptedTypeIdentifiers,
            delegate: LibraryPinnedItemDropDelegate(
                updateInsertionIndex: { location in
                    libraryDropInsertionIndex = nearestLibraryInsertionIndex(forY: location.y)
                },
                clearInsertionIndex: {
                    libraryDropInsertionIndex = nil
                },
                performPinnedDrop: { transfer, location in
                    let targetIndex = nearestLibraryInsertionIndex(forY: location.y)
                    return handlePinnedTransferDrop([transfer], targetIndex)
                },
                performLibraryRowDrop: { transfer, location in
                    let targetIndex = nearestLibraryInsertionIndex(forY: location.y)
                    return handleLibraryTransferDrop([transfer], targetIndex)
                },
                clearDragPreview: {
                    dragPreviewState.endDrag()
                }
            )
        )
        .background {
            GeometryReader { geo in
                Color.clear.preference(
                    key: LibraryRowFramePreferenceKey.self,
                    value: [row.id: geo.frame(in: .named("libraryDropArea"))]
                )
            }
        }
    }

    private var libraryLeadingDropSlot: some View {
        Color.clear
            .frame(height: 8)
            .contentShape(Rectangle())
            .onDrop(
                of: LibraryPinnedItemDropDelegate.acceptedTypeIdentifiers,
                delegate: LibraryPinnedItemDropDelegate(
                    updateInsertionIndex: { _ in
                        libraryDropInsertionIndex = 0
                    },
                    clearInsertionIndex: {
                        if libraryDropInsertionIndex == 0 {
                            libraryDropInsertionIndex = nil
                        }
                    },
                    performPinnedDrop: { transfer, _ in
                        handlePinnedTransferDrop([transfer], 0)
                    },
                    performLibraryRowDrop: { transfer, _ in
                        handleLibraryTransferDrop([transfer], 0)
                    },
                    clearDragPreview: {
                        dragPreviewState.endDrag()
                    }
                )
            )
            .listRowInsets(EdgeInsets())
    }

    private var libraryTrailingDropSlot: some View {
        VStack(spacing: 0) {
            if libraryDropInsertionIndex == libraryRows.count {
                PinnedDropSkeletonRow(item: dragPreviewState.activeItem)
            }
            Color.clear
                .frame(height: 12)
        }
        .contentShape(Rectangle())
        .onDrop(
            of: LibraryPinnedItemDropDelegate.acceptedTypeIdentifiers,
            delegate: LibraryPinnedItemDropDelegate(
                updateInsertionIndex: { location in
                    libraryDropInsertionIndex = nearestLibraryInsertionIndex(forY: location.y)
                },
                clearInsertionIndex: {
                    libraryDropInsertionIndex = nil
                },
                performPinnedDrop: { transfer, location in
                    let targetIndex = nearestLibraryInsertionIndex(forY: location.y)
                    return handlePinnedTransferDrop([transfer], targetIndex)
                },
                performLibraryRowDrop: { transfer, location in
                    let targetIndex = nearestLibraryInsertionIndex(forY: location.y)
                    return handleLibraryTransferDrop([transfer], targetIndex)
                },
                clearDragPreview: {
                    dragPreviewState.endDrag()
                }
            )
        )
        .listRowInsets(EdgeInsets())
    }

    private func nearestLibraryInsertionIndex(forY y: CGFloat) -> Int {
        guard !libraryRows.isEmpty else { return 0 }
        let framesInOrder = libraryRows.compactMap { libraryRowFramesByToken[$0.id] }
        guard !framesInOrder.isEmpty else { return 0 }
        for (index, frame) in framesInOrder.enumerated() {
            if y < frame.midY {
                return index
            }
        }
        return framesInOrder.count
    }
}
