import SwiftUI

extension PlaylistBrowserView {
    /// The playlist sidebar as shown/hidden, for Show/Hide Sidebar (#436). Showing it sets the
    /// same `.doubleColumn` the system toggle did, so a narrow window keeps today's behaviour:
    /// the `playlistColumnVisibility` observer closes the queue where both can't fit.
    var isSidebarVisibleBinding: Binding<Bool> {
        Binding(
            get: { playlistColumnVisibility != .detailOnly },
            set: { visible in playlistColumnVisibility = visible ? .doubleColumn : .detailOnly }
        )
    }

    func bindCommandPalette(queueVisible: Binding<Bool>, lyricsPresented: Binding<Bool>) {
        PlaylistBrowserCommandPaletteConfiguration.apply(
            to: commandPaletteManager,
            dependencies: .init(
                viewModel: viewModel,
                playbackViewModel: playbackViewModel,
                queueViewModel: queueViewModel,
                commandPaletteManager: commandPaletteManager,
                pinnedStore: pinnedStore,
                catalogProvider: catalogProvider,
                signOut: signOut,
                syncUnifiedRefreshRouting: { syncUnifiedRefreshRoutingToViewModel() },
                isPlaybackAvailable: playbackMode == .live,
                canDisconnect: canDisconnect
            ),
            queueVisible: queueVisible,
            lyricsPresented: lyricsPresented,
            sidebarVisible: isSidebarVisibleBinding
        )
    }
}

/// The title-bar sidebar button. It runs Show/Hide Sidebar like ⌘S, ⌃⌘S and the View menu,
/// instead of the system toggle that collapsed the split view by itself and cut the sidebar
/// off in a narrow window (#436).
struct PlaylistBrowserSidebarToggleButton: View {
    let isSidebarVisible: Bool
    let commandPaletteManager: CommandPaletteManager

    var body: some View {
        let title = isSidebarVisible
            ? SpotiglassL10n.string("menu.view.hideSidebar")
            : SpotiglassL10n.string("menu.view.showSidebar")
        Button {
            commandPaletteManager.execute(commandID: CommandPaletteCommandID.toggleSidebar)
        } label: {
            Label(title, systemImage: "sidebar.left")
        }
        .help(title)
    }
}
