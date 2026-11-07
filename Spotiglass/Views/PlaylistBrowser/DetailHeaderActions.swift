import SwiftUI

/// The collection a detail header starts when its playback action is pressed.
/// Most detail surfaces have a Spotify context URI; Liked Songs is a local
/// collection, so it starts the loaded playable URI list instead.
enum DetailHeaderPlaybackTarget: Equatable {
    /// `playlistID` is the sidebar row that shows the playing badge, like a double-clicked row
    /// of the same list (#396); `nil` for an artist.
    case context(uri: String, playlistID: String? = nil)
    case tracks(uris: [String], playlistID: String?)

    var isPlayable: Bool {
        switch self {
        case .context(let uri, _):
            !uri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .tracks(let uris, _):
            !uris.isEmpty
        }
    }
}

/// Keeps the playback semantics of the shared detail-header controls in one
/// place. Shuffle is an action, not a toggle here: it turns shuffle on when
/// needed and then starts the requested collection.
@MainActor
enum DetailHeaderPlayback {
    static func target(
        for detail: PlaylistDetailViewModel,
        service: MusicService = MusicServiceSelection.current
    ) -> DetailHeaderPlaybackTarget {
        let playlist = detail.playlist
        if playlist.id == SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID {
            return .tracks(
                uris: detail.tracks.compactMap(\.playableURI),
                playlistID: playlist.id
            )
        }
        let kind = playlist.isAlbumDetail ? "album" : "playlist"
        // The context URI names the service that owns the id: an Apple Music album id is
        // meaningless to Spotify and the other way round.
        let scheme = service == .appleMusic ? AppleMusicItemMapping.uriScheme : "spotify"
        return .context(uri: "\(scheme):\(kind):\(playlist.id)", playlistID: playlist.id)
    }

    static func target(for detail: ArtistDetailViewModel) -> DetailHeaderPlaybackTarget {
        .context(uri: detail.artist.uri)
    }

    static func play(
        target: DetailHeaderPlaybackTarget,
        using playbackViewModel: PlaybackSessionViewModel
    ) async {
        switch target {
        case .context(let uri, let playlistID):
            await playbackViewModel.play(contextURI: uri, playlistID: playlistID)
        case .tracks(let uris, let playlistID):
            guard let firstURI = uris.first else { return }
            await playbackViewModel.playFromPlaylist(
                clickedURI: firstURI,
                playableURIs: uris,
                playlistID: playlistID
            )
        }
    }

    static func shuffleAndPlay(
        target: DetailHeaderPlaybackTarget,
        using playbackViewModel: PlaybackSessionViewModel
    ) async {
        // Another service on screen: don't flip shuffle on an account whose play would be refused.
        guard !playbackViewModel.refusesNewPlayback else { return }
        if !playbackViewModel.shuffleEnabled {
            await playbackViewModel.toggleShuffle()
        }
        await play(target: target, using: playbackViewModel)
    }
}

/// Shared Play / Shuffle actions shown beside detail metadata.
struct DetailHeaderActions: View {
    let play: () async -> Void
    let shuffle: () async -> Void
    let hasPlaybackDevice: Bool
    let isAvailable: Bool

    init(
        play: @escaping () async -> Void,
        shuffle: @escaping () async -> Void,
        hasPlaybackDevice: Bool,
        isAvailable: Bool = true
    ) {
        self.play = play
        self.shuffle = shuffle
        self.hasPlaybackDevice = hasPlaybackDevice
        self.isAvailable = isAvailable
    }

    var body: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            Button {
                Task { @MainActor in await play() }
            } label: {
                Label(SpotiglassL10n.string("playback.play"), systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isEnabled)

            Button {
                Task { @MainActor in await shuffle() }
            } label: {
                Label(SpotiglassL10n.string("menu.playback.shuffle"), systemImage: "shuffle")
            }
            .buttonStyle(.bordered)
            .disabled(!isEnabled)
        }
        .controlSize(.regular)
        .accessibilityElement(children: .contain)
    }

    private var isEnabled: Bool {
        hasPlaybackDevice && isAvailable
    }
}
