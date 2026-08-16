import Foundation

struct ArtistAlbumRowViewModel: Equatable, Identifiable {
    let id: String
    let title: String
    let artworkURL: URL?
    let yearText: String?
    let trackCountText: String
    /// Kept as a number so nothing has to scrape digits off the localized
    /// ``trackCountText`` to recover it (#159).
    let totalTrackCount: Int
    let uri: String

    init(_ album: SpotifyArtistAlbum) {
        id = album.id
        title = album.name
        artworkURL = album.imageURL
        yearText = album.releaseYear
        totalTrackCount = max(0, album.totalTracks)
        trackCountText = album.totalTracks == 1
            ? SpotiglassL10n.string("browser.trackCount.one")
            : SpotiglassL10n.format("browser.trackCount.other", Int64(album.totalTracks))
        uri = album.uri
    }
}

struct ArtistDetailViewModel: Equatable {
    let artist: SpotifyArtistDetail
    let tracks: [TrackRowViewModel]
    let albums: [ArtistAlbumRowViewModel]
    let singles: [ArtistAlbumRowViewModel]
    let compilations: [ArtistAlbumRowViewModel]
    let appearsOn: [ArtistAlbumRowViewModel]
    let canLoadMoreAlbums: Bool
    let isLoadingMoreAlbums: Bool

    init(
        artist: SpotifyArtistDetail,
        tracks: [SpotifyTrack],
        albums: [SpotifyArtistAlbum],
        canLoadMoreAlbums: Bool = false,
        isLoadingMoreAlbums: Bool = false
    ) {
        self.artist = artist
        self.tracks = TrackRowViewModel.numberedTopTracks(tracks)
        let grouped = Dictionary(grouping: albums, by: \.group)
        let sort: (SpotifyArtistAlbum, SpotifyArtistAlbum) -> Bool = { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        self.albums = (grouped[.album] ?? []).sorted(by: sort).map(ArtistAlbumRowViewModel.init)
        self.singles = (grouped[.single] ?? []).sorted(by: sort).map(ArtistAlbumRowViewModel.init)
        self.compilations = (grouped[.compilation] ?? []).sorted(by: sort).map(ArtistAlbumRowViewModel.init)
        self.appearsOn = (grouped[.appearsOn] ?? []).sorted(by: sort).map(ArtistAlbumRowViewModel.init)
        self.canLoadMoreAlbums = canLoadMoreAlbums
        self.isLoadingMoreAlbums = isLoadingMoreAlbums
    }
}

extension ArtistAlbumRowViewModel {

    func spotifyArtistAlbum(group: SpotifyArtistAlbumGroup) -> SpotifyArtistAlbum {
        SpotifyArtistAlbum(
            id: id,
            name: title,
            imageURL: artworkURL,
            releaseYear: yearText,
            totalTracks: totalTrackCount,
            group: group,
            uri: uri
        )
    }

    func pinnedAlbum(group: SpotifyArtistAlbumGroup) -> PinnedItem {
        .album(spotifyArtistAlbum(group: group))
    }
}
