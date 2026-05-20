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
                spotifySearchClient: spotifySearchClient,
                signOut: signOut,
                syncUnifiedRefreshRouting: { syncUnifiedRefreshRoutingToViewModel() }
            ),
            queueVisible: queueVisible,
            lyricsPresented: lyricsPresented
        )
    }
}
