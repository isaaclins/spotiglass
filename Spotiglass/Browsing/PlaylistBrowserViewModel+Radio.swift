import Foundation

extension PlaylistBrowserViewModel {
    /// Starts a radio station seeded by a track.
    func startTrackRadio(seedTrack: TrackRowViewModel, playbackViewModel: PlaybackSessionViewModel) async {
        let seedID = seedTrack.id
        var playableURIs: [String] = []
        if let seedURI = seedTrack.playableURI {
            playableURIs.append(seedURI)
        }

        do {
            let recommended = try await api.recommendations(
                seedTracks: [seedID],
                seedArtistName: seedTrack.subtitle,
                seedTrackName: seedTrack.title,
                limit: 30
            )
            for track in recommended {
                let uri = track.uri
                guard !playableURIs.contains(uri) else { continue }
                playableURIs.append(uri)
            }
        } catch {
            SpotiglassLog.error(.api, "startTrackRadio failed for \(seedTrack.title): \(error.localizedDescription)")
        }

        guard let firstURI = playableURIs.first else {
            trackMutationToast = "Unable to start radio for \(seedTrack.title)"
            return
        }

        await playbackViewModel.playFromPlaylist(clickedURI: firstURI, playableURIs: playableURIs)
        trackMutationToast = "Radio started: Based on '\(seedTrack.title)'"
    }

    /// Starts a radio station seeded by an artist.
    func startArtistRadio(artistID: String, artistName: String, playbackViewModel: PlaybackSessionViewModel) async {
        var playableURIs: [String] = []

        do {
            let recommended = try await api.recommendations(
                seedArtists: [artistID],
                seedArtistName: artistName,
                limit: 30
            )
            playableURIs = recommended.map(\.uri)
        } catch {
            SpotiglassLog.error(.api, "startArtistRadio failed for \(artistName): \(error.localizedDescription)")
        }

        guard let firstURI = playableURIs.first else {
            trackMutationToast = "Unable to start radio for \(artistName)"
            return
        }

        await playbackViewModel.playFromPlaylist(clickedURI: firstURI, playableURIs: playableURIs)
        trackMutationToast = "Radio started: Based on '\(artistName)'"
    }
}
