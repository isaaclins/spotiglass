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

/// Always-visible browser feedback for the bulk playlist-track prefetch. This
/// lives in the main window toolbar rather than the palette so a menu-bar run
/// is observable and cancellable without opening another surface.
struct PlaylistBrowserPrefetchProgressToolbarItem: View {
    let progress: PrefetchAllPlaylistsProgress
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: SpotiglassDesign.spacingXS) {
            Image(systemName: iconName)
                .foregroundStyle(.secondary)
            if progress.phase == .running, progress.total > 0 {
                ProgressView(
                    value: Double(progress.processedCount),
                    total: Double(progress.total)
                )
                .progressViewStyle(.linear)
                .frame(width: 72)
            }
            Text(progress.localizedStatusLabel)
                .font(.caption)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if progress.phase == .running {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(SpotiglassL10n.string("palette.cancelPrefetch"))
                .accessibilityLabel(SpotiglassL10n.string("palette.cancelPrefetch"))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(progress.localizedStatusLabel)
    }

    private var iconName: String {
        switch progress.phase {
        case .running:
            "arrow.down.circle"
        case .finished:
            "checkmark.circle.fill"
        case .cancelled:
            "xmark.circle"
        }
    }
}
