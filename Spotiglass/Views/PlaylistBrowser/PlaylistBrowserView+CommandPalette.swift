import SwiftUI

extension PlaylistBrowserView {
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
                isPlaybackAvailable: playbackMode == .live
            ),
            queueVisible: queueVisible,
            lyricsPresented: lyricsPresented
        )
    }
}
