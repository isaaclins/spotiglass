import Foundation

// Service-neutral library models used by browsing UI and playback context.
//
// Every music service maps its own wire format into these types. Spotify's
// decoding lives in `Services/SpotifyDTOs+*.swift` (`*DTO`) and maps here via
// `domainModel()`. A later Apple Music provider maps MusicKit items the same way.
//
// `id` is the service's own identifier and `uri` is a playback reference that
// should only be interpreted by the owning service (for Spotify a
// `spotify:track:...` URI). Not there yet: several browsing view models, views
// and pins still check for the `spotify:track:` prefix (see "Music providers"
// in docs/architecture.md).
//
// The type names changed from `Spotify*` to `Music*`, but the Codable shape did
// not: playlist and track caches written by earlier builds keep decoding.

struct MusicUserProfile: Codable, Equatable {
    let id: String
    let displayName: String?
    let country: String?
}

struct MusicPlaylistSummary: Codable, Equatable, Identifiable {
    let id: String
    /// The name as the service sent it, maybe blank; ``name`` is what to show (#547).
    private let storedName: String
    let ownerID: String
    let ownerName: String
    let imageURL: URL?
    let trackCount: Int?
    let snapshotID: String
    /// A Spotify playlist its owner opened to collaborators, which they may reorder too (#543).
    /// Caches written before this existed decode it as `false`.
    let isCollaborative: Bool

    var name: String {
        UnnamedMusicItem.displayName(storedName, kind: .playlist)
    }

    /// ``ownerName`` as the sidebar shows it: an Apple Music library playlist's owner is "You"
    /// in the app's current language, not in the one the result was loaded in (#548).
    var ownerNameInAppLanguage: String {
        AppleMusicItemMapping.localizedOwnerName(ownerName, ownerID: ownerID, locale: SpotiglassL10n.locale)
    }

    /// True when ``name`` is the stand-in, which rows and pins resolve again when they render.
    var isUnnamed: Bool {
        UnnamedMusicItem.isStandIn(storedName, kind: .playlist)
    }

    /// The name exactly as the service sent it (or an earlier build saved it), for copies that
    /// resolve it again when they render: a pin, a row rebuilt into a playlist. A real name that
    /// reads like a stand-in is kept that way instead of being saved blank.
    var nameAsSent: String {
        storedName
    }

    init(
        id: String,
        name: String,
        ownerID: String,
        ownerName: String,
        imageURL: URL?,
        trackCount: Int?,
        snapshotID: String,
        isCollaborative: Bool = false
    ) {
        self.id = id
        self.storedName = name
        self.ownerID = ownerID
        self.ownerName = ownerName
        self.imageURL = imageURL
        self.trackCount = trackCount
        self.snapshotID = snapshotID
        self.isCollaborative = isCollaborative
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case storedName = "name"
        case ownerID, ownerName, imageURL, trackCount, snapshotID, isCollaborative
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        storedName = try container.decode(String.self, forKey: .storedName)
        ownerID = try container.decode(String.self, forKey: .ownerID)
        ownerName = try container.decode(String.self, forKey: .ownerName)
        imageURL = try container.decodeIfPresent(URL.self, forKey: .imageURL)
        trackCount = try container.decodeIfPresent(Int.self, forKey: .trackCount)
        snapshotID = try container.decode(String.self, forKey: .snapshotID)
        isCollaborative = try container.decodeIfPresent(Bool.self, forKey: .isCollaborative) ?? false
    }

    /// The same playlist with another track count. Keeps the name as the service sent it, so a
    /// playlist without one keeps following the app's language (#547).
    func with(trackCount: Int?) -> MusicPlaylistSummary {
        MusicPlaylistSummary(
            id: id,
            name: storedName,
            ownerID: ownerID,
            ownerName: ownerName,
            imageURL: imageURL,
            trackCount: trackCount,
            snapshotID: snapshotID,
            isCollaborative: isCollaborative
        )
    }

    /// The same playlist at the snapshot an edit made from here returned (#543).
    func with(snapshotID: String) -> MusicPlaylistSummary {
        MusicPlaylistSummary(
            id: id,
            name: storedName,
            ownerID: ownerID,
            ownerName: ownerName,
            imageURL: imageURL,
            trackCount: trackCount,
            snapshotID: snapshotID,
            isCollaborative: isCollaborative
        )
    }
}

struct MusicPlaylistTrackItem: Codable, Equatable, Identifiable {
    let id: String
    let content: MusicPlaylistItemContent
}

/// A new order for the rows of a playlist as they are shown: `order[i]` is the current position
/// (zero-based) of the row that goes to position `i`. `currentTrackIDs` are the rows' track IDs in
/// their current order (`nil` for a row without one), for a provider that has to check it is
/// moving the rows that are shown. Rows past the end of `order` (not loaded yet) stay where
/// they are.
struct MusicPlaylistReorder: Equatable {
    let order: [Int]
    let currentTrackIDs: [String?]
}

/// Spotify lists the playlist differently than the rows the new order was counted in: it changed
/// elsewhere since it was read, so the order isn't sent (#543).
struct MusicPlaylistChangedElsewhere: LocalizedError, Equatable {
    var errorDescription: String? { SpotiglassL10n.string("playlist.mutation.reorderChangedElsewhere") }
}

/// A reorder the service took only part of: Spotify saves an order one request at a time, and
/// one after the first failed. `orderSoFar` is the order the playlist has now (like
/// `MusicPlaylistReorder.order`), `snapshotID` the one the last request that went through
/// returned, `underlying` why the next one failed.
struct MusicPlaylistReorderPartialFailure: Error {
    let orderSoFar: [Int]
    let snapshotID: String?
    let underlying: Error
}

/// One Spotify reorder request: `rangeLength` items from `rangeStart` go before the item at
/// `insertBefore`, positions counted in the playlist before this request.
struct MusicPlaylistRangeMove: Equatable {
    let rangeStart: Int
    let rangeLength: Int
    let insertBefore: Int
}

/// One or more exact positions for a URI in a playlist mutation.
struct MusicPlaylistTrackRemoval: Equatable {
    let uri: String
    let positions: [Int]
}

/// Paged result from `GET /v1/me/tracks` (Liked Songs). `totalAvailable` is Spotify's total; `tracks` is complete unless a caller explicitly caps pagination.
struct MusicSavedTracksResult: Equatable {
    let tracks: [MusicPlaylistTrackItem]
    let totalAvailable: Int
}

enum MusicPlaylistItemContent: Codable, Equatable {
    case track(MusicTrack)
    case episode(MusicEpisode)
    case localTrack(MusicLocalTrack)
    case unavailable(reason: MusicUnavailableReason)
}

/// Why a playlist entry can't be played. The row turns this into a sentence in the app's
/// language when it is shown, so the reason must not be stored as display text: rows are
/// cached on disk and outlive a language switch (#492).
enum MusicUnavailableReason: String, Codable, Equatable {
    case track
    case episode
    case noPlayableContent

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        if let reason = MusicUnavailableReason(rawValue: value) {
            self = reason
            return
        }
        // Caches written before #492 stored the English sentence itself.
        switch value {
        case "Track is unavailable.": self = .track
        case "Episode is unavailable.": self = .episode
        default: self = .noPlayableContent
        }
    }
}

struct MusicArtistRef: Codable, Equatable, Identifiable {
    let id: String
    /// The name as the service sent it, maybe blank; ``name`` is what to show (#547).
    private let storedName: String

    var name: String {
        UnnamedMusicItem.displayName(storedName, kind: .artist)
    }

    init(id: String, name: String) {
        self.id = id
        self.storedName = name
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case storedName = "name"
    }
}

struct MusicTrack: Equatable, Identifiable {
    let id: String
    /// Name and artist names as the service sent them, maybe blank; ``name`` and ``artists``
    /// are what to show (#547).
    private let storedName: String
    private let storedArtists: [String]
    /// Present when Spotify returned artist IDs (playlist/search tracks). Used for tappable artist links.
    let artistRefs: [MusicArtistRef]
    let albumArtworkURL: URL?
    let albumName: String?
    let albumID: String?
    let durationMilliseconds: Int
    let isExplicit: Bool
    let isPlayable: Bool?
    let linkedFromID: String?
    let uri: String

    init(
        id: String,
        name: String,
        artists: [String],
        artistRefs: [MusicArtistRef] = [],
        albumArtworkURL: URL?,
        albumName: String? = nil,
        albumID: String? = nil,
        durationMilliseconds: Int,
        isExplicit: Bool,
        isPlayable: Bool?,
        linkedFromID: String?,
        uri: String
    ) {
        self.id = id
        self.storedName = name
        self.storedArtists = artists
        self.artistRefs = artistRefs
        self.albumArtworkURL = albumArtworkURL
        self.albumName = albumName
        self.albumID = albumID
        self.durationMilliseconds = durationMilliseconds
        self.isExplicit = isExplicit
        self.isPlayable = isPlayable
        self.linkedFromID = linkedFromID
        self.uri = uri
    }

    var name: String {
        UnnamedMusicItem.displayName(storedName, kind: .track)
    }

    var artists: [String] {
        UnnamedMusicItem.displayNames(storedArtists, kind: .artist)
    }
}

extension MusicTrack: Codable {
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case artists
        case artistRefs
        case albumArtworkURL
        case albumName
        case albumID
        case durationMilliseconds
        case isExplicit
        case isPlayable
        case linkedFromID
        case uri
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        storedName = try c.decode(String.self, forKey: .name)
        storedArtists = try c.decode([String].self, forKey: .artists)
        artistRefs = try c.decodeIfPresent([MusicArtistRef].self, forKey: .artistRefs) ?? []
        albumArtworkURL = try c.decodeIfPresent(URL.self, forKey: .albumArtworkURL)
        albumName = try c.decodeIfPresent(String.self, forKey: .albumName)
        albumID = try c.decodeIfPresent(String.self, forKey: .albumID)
        durationMilliseconds = try c.decode(Int.self, forKey: .durationMilliseconds)
        isExplicit = try c.decode(Bool.self, forKey: .isExplicit)
        isPlayable = try c.decodeIfPresent(Bool.self, forKey: .isPlayable)
        linkedFromID = try c.decodeIfPresent(String.self, forKey: .linkedFromID)
        uri = try c.decode(String.self, forKey: .uri)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(storedName, forKey: .name)
        try c.encode(storedArtists, forKey: .artists)
        try c.encode(artistRefs, forKey: .artistRefs)
        try c.encodeIfPresent(albumArtworkURL, forKey: .albumArtworkURL)
        try c.encodeIfPresent(albumName, forKey: .albumName)
        try c.encodeIfPresent(albumID, forKey: .albumID)
        try c.encode(durationMilliseconds, forKey: .durationMilliseconds)
        try c.encode(isExplicit, forKey: .isExplicit)
        try c.encodeIfPresent(isPlayable, forKey: .isPlayable)
        try c.encodeIfPresent(linkedFromID, forKey: .linkedFromID)
        try c.encode(uri, forKey: .uri)
    }
}

struct MusicArtistDetail: Codable, Equatable, Identifiable {
    let id: String
    /// The name as the service sent it, maybe blank; ``name`` is what to show (#547).
    private let storedName: String
    let imageURL: URL?
    let followersTotal: Int?
    let genres: [String]
    let uri: String

    var name: String {
        UnnamedMusicItem.displayName(storedName, kind: .artist)
    }

    init(id: String, name: String, imageURL: URL?, followersTotal: Int?, genres: [String], uri: String) {
        self.id = id
        self.storedName = name
        self.imageURL = imageURL
        self.followersTotal = followersTotal
        self.genres = genres
        self.uri = uri
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case storedName = "name"
        case imageURL, followersTotal, genres, uri
    }
}

enum MusicArtistAlbumGroup: String, Codable, Equatable, CaseIterable {
    case album
    case single
    case compilation
    case appearsOn = "appears_on"
}

/// How far back "top" items (most played tracks and artists) look.
enum MusicTopItemsTimeRange: String, Equatable {
    /// Roughly the last four weeks.
    case shortTerm = "short_term"
    /// Roughly the last six months.
    case mediumTerm = "medium_term"
    /// Several years.
    case longTerm = "long_term"
}

struct MusicArtistAlbum: Codable, Equatable, Identifiable {
    let id: String
    /// The name as the service sent it, maybe blank; ``name`` is what to show (#547).
    private let storedName: String
    let imageURL: URL?
    let releaseYear: String?
    let totalTracks: Int
    let group: MusicArtistAlbumGroup
    let uri: String

    var name: String {
        UnnamedMusicItem.displayName(storedName, kind: .album)
    }

    init(
        id: String,
        name: String,
        imageURL: URL?,
        releaseYear: String?,
        totalTracks: Int,
        group: MusicArtistAlbumGroup,
        uri: String
    ) {
        self.id = id
        self.storedName = name
        self.imageURL = imageURL
        self.releaseYear = releaseYear
        self.totalTracks = totalTracks
        self.group = group
        self.uri = uri
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case storedName = "name"
        case imageURL, releaseYear, totalTracks, group, uri
    }
}

struct MusicArtist: Codable, Equatable, Identifiable {
    let id: String
    /// The name as the service sent it, maybe blank; ``name`` is what to show (#547).
    private let storedName: String
    let imageURL: URL?
    let uri: String

    var name: String {
        UnnamedMusicItem.displayName(storedName, kind: .artist)
    }

    init(id: String, name: String, imageURL: URL?, uri: String) {
        self.id = id
        self.storedName = name
        self.imageURL = imageURL
        self.uri = uri
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case storedName = "name"
        case imageURL, uri
    }
}

struct MusicAlbum: Codable, Equatable, Identifiable {
    let id: String
    /// Name and artist names as the service sent them, maybe blank; ``name`` and ``artists``
    /// are what to show (#547).
    private let storedName: String
    private let storedArtists: [String]
    /// The artists by ID when the service gave them, so a card can link each one (#478).
    let artistRefs: [MusicArtistRef]
    let imageURL: URL?
    let uri: String

    init(
        id: String,
        name: String,
        artists: [String],
        artistRefs: [MusicArtistRef] = [],
        imageURL: URL?,
        uri: String
    ) {
        self.id = id
        self.storedName = name
        self.storedArtists = artists
        self.artistRefs = artistRefs
        self.imageURL = imageURL
        self.uri = uri
    }

    var name: String {
        UnnamedMusicItem.displayName(storedName, kind: .album)
    }

    var artists: [String] {
        UnnamedMusicItem.displayNames(storedArtists, kind: .artist)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case storedName = "name"
        case storedArtists = "artists"
        case artistRefs, imageURL, uri
    }

    func withArtistRefs(_ refs: [MusicArtistRef]) -> MusicAlbum {
        MusicAlbum(id: id, name: storedName, artists: storedArtists, artistRefs: refs, imageURL: imageURL, uri: uri)
    }

    /// Albums cached before `artistRefs` existed decode with none.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        storedName = try c.decode(String.self, forKey: .storedName)
        storedArtists = try c.decode([String].self, forKey: .storedArtists)
        artistRefs = try c.decodeIfPresent([MusicArtistRef].self, forKey: .artistRefs) ?? []
        imageURL = try c.decodeIfPresent(URL.self, forKey: .imageURL)
        uri = try c.decode(String.self, forKey: .uri)
    }
}

struct MusicSearchPaging: Codable, Equatable {
    let total: Int
    let next: URL?
}

struct MusicSearchResults: Codable, Equatable {
    let tracks: [MusicTrack]
    let artists: [MusicArtist]
    let albums: [MusicAlbum]
    let playlists: [MusicPlaylistSummary]
    let tracksPaging: MusicSearchPaging?
    let artistsPaging: MusicSearchPaging?
    let albumsPaging: MusicSearchPaging?
    let playlistsPaging: MusicSearchPaging?

    init(
        tracks: [MusicTrack],
        artists: [MusicArtist],
        albums: [MusicAlbum],
        playlists: [MusicPlaylistSummary],
        tracksPaging: MusicSearchPaging? = nil,
        artistsPaging: MusicSearchPaging? = nil,
        albumsPaging: MusicSearchPaging? = nil,
        playlistsPaging: MusicSearchPaging? = nil
    ) {
        self.tracks = tracks
        self.artists = artists
        self.albums = albums
        self.playlists = playlists
        self.tracksPaging = tracksPaging
        self.artistsPaging = artistsPaging
        self.albumsPaging = albumsPaging
        self.playlistsPaging = playlistsPaging
    }
}

struct MusicEpisode: Codable, Equatable, Identifiable {
    let id: String
    /// Names as the service sent them, maybe blank; ``name`` and ``showName`` are what to
    /// show (#547).
    private let storedName: String
    private let storedShowName: String?
    let artworkURL: URL?
    let durationMilliseconds: Int
    let isPlayable: Bool?
    let uri: String

    var name: String {
        UnnamedMusicItem.displayName(storedName, kind: .episode)
    }

    /// `nil` when the show has no name: rows then say what the item is instead.
    var showName: String? {
        storedShowName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? storedShowName : nil
    }

    init(
        id: String,
        name: String,
        showName: String?,
        artworkURL: URL?,
        durationMilliseconds: Int,
        isPlayable: Bool?,
        uri: String
    ) {
        self.id = id
        self.storedName = name
        self.storedShowName = showName
        self.artworkURL = artworkURL
        self.durationMilliseconds = durationMilliseconds
        self.isPlayable = isPlayable
        self.uri = uri
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case storedName = "name"
        case storedShowName = "showName"
        case artworkURL, durationMilliseconds, isPlayable, uri
    }
}

struct MusicLocalTrack: Codable, Equatable {
    /// Name and artist names as the file has them, maybe blank; ``name`` and ``artists`` are
    /// what to show (#547).
    private let storedName: String
    private let storedArtists: [String]
    let durationMilliseconds: Int
    let uri: String

    var name: String {
        UnnamedMusicItem.displayName(storedName, kind: .track)
    }

    var artists: [String] {
        UnnamedMusicItem.displayNames(storedArtists, kind: .artist)
    }

    init(name: String, artists: [String], durationMilliseconds: Int, uri: String) {
        self.storedName = name
        self.storedArtists = artists
        self.durationMilliseconds = durationMilliseconds
        self.uri = uri
    }

    private enum CodingKeys: String, CodingKey {
        case storedName = "name"
        case storedArtists = "artists"
        case durationMilliseconds, uri
    }
}

extension LocalizedText {
    /// A name as a model showed it: fixed text, unless it is a stand-in ("Unknown track"),
    /// which is looked up again when shown. Real names cost nothing to read or compare.
    static func musicName(_ shown: String, kind: UnnamedMusicItem) -> LocalizedText {
        guard UnnamedMusicItem.isStandIn(shown, kind: kind) else { return LocalizedText(verbatim: shown) }
        return LocalizedText(UnnamedMusicItem.displayName(shown, kind: kind), comparedBy: shown)
    }

    /// Names joined with ", ", each stand-in among them looked up again when shown.
    static func musicNames(_ shown: [String], kind: UnnamedMusicItem) -> LocalizedText {
        let joined = shown.joined(separator: ", ")
        guard shown.contains(where: { UnnamedMusicItem.isStandIn($0, kind: kind) }) else {
            return LocalizedText(verbatim: joined)
        }
        return LocalizedText(UnnamedMusicItem.displayNames(shown, kind: kind).joined(separator: ", "), comparedBy: joined)
    }
}

/// What an item the service sent without a name is called: a removed track, a deleted artist,
/// a playlist without a title. The models keep the name as the service sent it and look the
/// stand-in up each time the name is read, so it is always in the app's language, also for
/// items cached on disk before a language switch (#547).
enum UnnamedMusicItem: CaseIterable {
    case track
    case episode
    case artist
    case album
    case playlist

    /// The stand-in's localization key, for a place that marks a stand-in instead of keeping its text.
    var key: String {
        switch self {
        case .track: "music.unnamed.track"
        case .episode: "music.unnamed.episode"
        case .artist: "music.unnamed.artist"
        case .album: "music.unnamed.album"
        case .playlist: "music.unnamed.playlist"
        }
    }

    /// The stand-in in the app's current language.
    var placeholder: String {
        SpotiglassL10n.string(key)
    }

    func placeholder(locale: Locale) -> String {
        SpotiglassL10n.string(key, locale: locale)
    }

    /// `name`, or the stand-in when it is blank or is a stand-in itself (see ``isStandIn(_:kind:)``).
    static func displayName(_ name: String, kind: UnnamedMusicItem) -> String {
        standInKind(of: name, kind: kind)?.placeholder ?? name
    }

    static func displayName(_ name: String, kind: UnnamedMusicItem, locale: Locale) -> String {
        standInKind(of: name, kind: kind)?.placeholder(locale: locale) ?? name
    }

    static func displayNames(_ names: [String], kind: UnnamedMusicItem) -> [String] {
        names.map { displayName($0, kind: kind) }
    }

    /// Artist names joined with ", " (a pin's or a queue row's subtitle), with each stand-in among
    /// them in `locale`'s language. A blank text stays blank: it means no artists, not a nameless one.
    static func displayArtistList(_ text: String, locale: Locale) -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        return text.components(separatedBy: ", ")
            .map { displayName($0, kind: .artist, locale: locale) }
            .joined(separator: ", ")
    }

    /// True for a blank name, and for a stand-in saved as the name itself: by builds before #547,
    /// or copied from a model into a pin, a row or the queue. Such a copy follows the language
    /// again. Only the exact stand-ins count: "Unknown Artist" (local files) and Music's own
    /// "Untitled Playlist" are real names, so the playlist stand-in is only recognised as older
    /// builds wrote it. A saved stand-in only counts for its own kind, so a playlist really named
    /// "Unbekannter Titel" keeps that name; tracks and episodes share the queue and the player
    /// bar, so there a copied "Unknown episode" stays an episode.
    static func isStandIn(_ name: String, kind: UnnamedMusicItem) -> Bool {
        standInKind(of: name, kind: kind) != nil
    }

    private static func standInKind(of name: String, kind: UnnamedMusicItem) -> UnnamedMusicItem? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return kind }
        guard let saved = savedStandIns[name] else { return nil }
        if saved == kind { return saved }
        let playable: Set<UnnamedMusicItem> = [.track, .episode]
        return playable.contains(saved) && playable.contains(kind) ? saved : nil
    }

    private static let savedStandIns: [String: UnnamedMusicItem] = {
        var kinds: [String: UnnamedMusicItem] = [
            "Unknown track": .track,
            "Unknown episode": .episode,
            "Unknown artist": .artist,
            "Untitled playlist": .playlist,
            // What earlier builds saved for an Apple Music playlist without a name in German and
            // Spanish. The English one, "Untitled Playlist", is also Music's own name for a new
            // playlist, so it stays a name.
            "Unbenannte Playlist": .playlist,
            "Lista sin título": .playlist
        ]
        for kind in [UnnamedMusicItem.track, .episode, .artist, .album] {
            for language in AppLanguage.allCases {
                kinds[SpotiglassL10n.string(kind.key, locale: Locale(identifier: language.rawValue))] = kind
            }
        }
        return kinds
    }()
}
