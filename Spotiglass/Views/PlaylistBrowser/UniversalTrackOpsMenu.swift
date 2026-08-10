import SwiftUI

struct UniversalTrackOpsMenu: View {
    let track: TrackRowViewModel
    @ObservedObject var viewModel: PlaylistBrowserViewModel
    @ObservedObject var playbackViewModel: PlaybackSessionViewModel

    @State private var isPromptingNewPlaylist = false
    @State private var newPlaylistName = ""

    var body: some View {
        Group {
            Button(SpotiglassL10n.string("browser.track.startRadio")) {
                Task {
                    await viewModel.startTrackRadio(seedTrack: track, playbackViewModel: playbackViewModel)
                }
            }

            let userPlaylists = viewModel.userOwnedPlaylistsForMenu(excludingPlaylistID: nil)
            Menu(SpotiglassL10n.string("browser.addToPlaylist")) {
                Button(SpotiglassL10n.string("playlist.detail.newPlaylist.menuItem")) {
                    isPromptingNewPlaylist = true
                }
                if !userPlaylists.isEmpty { Divider() }
                ForEach(userPlaylists, id: \.id) { dest in
                    Button(dest.name) {
                        Task {
                            await viewModel.addRowsToPlaylist(
                                [track],
                                playlistID: dest.id,
                                playlistName: dest.name
                            )
                        }
                    }
                }
            }

            Button(SpotiglassL10n.string("browser.likedSongs.add")) {
                Task { await viewModel.favoriteRows([track]) }
            }

            Button(SpotiglassL10n.string("browser.likedSongs.remove")) {
                Task { await viewModel.unfavoriteRows([track]) }
            }
        }
        .alert(SpotiglassL10n.string("playlist.detail.newPlaylist.title"), isPresented: $isPromptingNewPlaylist) {
            TextField(SpotiglassL10n.string("playlist.detail.newPlaylist.field"), text: $newPlaylistName)
            Button(SpotiglassL10n.string("playlist.detail.newPlaylist.cancel"), role: .cancel) {
                newPlaylistName = ""
            }
            Button(SpotiglassL10n.string("playlist.detail.newPlaylist.create")) {
                let name = newPlaylistName
                newPlaylistName = ""
                Task { await viewModel.createPlaylistWithRows(name: name, rows: [track]) }
            }
            .disabled(newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: {
            Text("Create a new playlist and add '\(track.title)' to it.")
        }
    }
}
