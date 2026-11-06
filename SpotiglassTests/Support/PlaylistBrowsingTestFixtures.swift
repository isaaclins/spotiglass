import Foundation
@testable import Spotiglass

enum PlaylistBrowsingTestFixtures {
    static func playlistTracks(_ state: BrowsingLoadState<BrowsingDetailContent>) -> [TrackRowViewModel] {
        guard let content = state.currentValue else { return [] }
        if case let .playlist(detail) = content {
            return detail.tracks
        }
        return []
    }

    static func playlist(id: String, name: String, snapshotID: String = "snapshot-\(UUID().uuidString)") -> MusicPlaylistSummary {
        MusicPlaylistSummary(
            id: id,
            name: name,
            ownerID: "owner-id",
            ownerName: "Owner",
            imageURL: nil,
            trackCount: 1,
            snapshotID: snapshotID
        )
    }

    static func fallbackTrack(id: String, name: String, artistId: String) -> MusicTrack {
        MusicTrack(
            id: id,
            name: name,
            artists: ["Artist \(artistId)"],
            artistRefs: [MusicArtistRef(id: artistId, name: "Artist \(artistId)")],
            albumArtworkURL: nil,
            durationMilliseconds: 100_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "spotify:track:\(id)"
        )
    }

    static func track(id: String) -> MusicPlaylistTrackItem {
        MusicPlaylistTrackItem(
            id: id,
            content: .track(MusicTrack(
                id: id,
                name: "Track \(id)",
                artists: ["Artist"],
                albumArtworkURL: nil,
                durationMilliseconds: 180_000,
                isExplicit: false,
                isPlayable: true,
                linkedFromID: nil,
                uri: "spotify:track:\(id)"
            ))
        )
    }
}
