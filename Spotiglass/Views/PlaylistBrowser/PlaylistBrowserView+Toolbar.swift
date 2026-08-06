import SwiftUI

extension PlaylistBrowserView {
    var unifiedRefreshToolbarButton: some View {
        Button {
            Task { await performUnifiedToolbarRefresh() }
        } label: {
            refreshToolbarLabelIconAndText
        }
        .buttonStyle(.borderless)
        .disabled(isUnifiedRefreshBusy)
        .help(SpotiglassL10n.string("tooltip.toolbar.refresh"))
        .accessibilityHint(
            SpotiglassL10n.string("browser.toolbar.refreshHelp")
        )
    }

    /// Icon + “Refresh” label; horizontal padding keeps the borderless primary-action item clear of the toolbar edge.
    var refreshToolbarLabelIconAndText: some View {
        refreshToolbarLabelCore
            .padding(.horizontal, SpotiglassDesign.spacingM)
    }

    var refreshToolbarLabelCore: some View {
        HStack(spacing: SpotiglassDesign.spacingXS) {
            Group {
                if isUnifiedRefreshBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.body.weight(.medium))
                }
            }
            .frame(width: 16, height: 16)
            Text(SpotiglassL10n.string("browser.refresh"))
        }
    }

    var isUnifiedRefreshBusy: Bool {
        if lyricsOverlay.isPresented {
            return isPlaylistOrDetailRefreshing
        }
        if isQueueVisible, unifiedRefreshFocus == .queuePanel {
            return viewModel.isUnifiedQueueRefreshActive
        }
        return isPlaylistOrDetailRefreshing
    }

    var isPlaylistOrDetailRefreshing: Bool {
        if case .refreshing = viewModel.playlistState { return true }
        if case .refreshing = viewModel.detailState { return true }
        return false
    }

    func syncUnifiedRefreshRoutingToViewModel() {
        viewModel.refreshRoutingLyricsPresented = lyricsOverlay.isPresented
        viewModel.refreshRoutingQueuePanelVisible = isQueueVisible
        viewModel.refreshRoutingQueuePanelFocused = unifiedRefreshFocus == .queuePanel
    }

    func performUnifiedToolbarRefresh() async {
        syncUnifiedRefreshRoutingToViewModel()
        await viewModel.performUnifiedRefresh { await queueViewModel.refreshQueue() }
    }
}
