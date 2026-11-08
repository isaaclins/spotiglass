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
