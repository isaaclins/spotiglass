import Foundation
import MusicKit

/// Why an Apple Music library edit did not happen. Every case reads as one calm line, because
/// the browser shows `localizedDescription` as its toast.
enum AppleMusicLibraryEditError: LocalizedError, Equatable {
    /// The user said no to "Spotiglass wants to control Music" (or has not answered yet).
    case musicControlDenied
    /// The Music app did not start or did not answer.
    case musicUnavailable
    /// The item was changed through Apple Music moments ago and the Music app on this Mac has not
    /// received it yet, so Music can't find it to change it again.
    case notInMusicYet
    /// Two editable playlists share the name Apple Music needs to tell them apart.
    case ambiguousPlaylist
    /// Neither route can change this item (a song without an Apple Music ID, Apple's own playlists).
    case notEditable
    /// Apple Music answered with an error.
    case requestFailed

    var errorDescription: String? {
        switch self {
        case .musicControlDenied:
            SpotiglassL10n.string("appleMusic.edit.error.musicControlDenied")
        case .musicUnavailable:
            SpotiglassL10n.string("appleMusic.edit.error.musicUnavailable")
        case .notInMusicYet:
            SpotiglassL10n.string("appleMusic.edit.error.notInMusicYet")
        case .ambiguousPlaylist:
            SpotiglassL10n.string("appleMusic.edit.error.ambiguousPlaylist")
        case .notEditable:
            SpotiglassL10n.string("appleMusic.edit.error.notEditable")
        case .requestFailed:
            SpotiglassL10n.string("appleMusic.edit.error.requestFailed")
        }
    }
}

/// A song with every ID the two edit routes need.
///
/// MusicKit shows a library song under one ID (a cloud library ID `i.…`, or the Music app's
/// persistent ID as a signed decimal), a catalog song under its catalog ID. The Apple Music API
/// wants catalog or cloud library IDs; the Music app wants its persistent ID.
struct AppleMusicSongReference: Equatable, Sendable {
    /// The ID the browser shows for the song.
    let itemID: String
    var catalogID: String?
    /// Cloud library ID (`i.…`), when the song is in the iCloud Music Library.
    var cloudLibraryID: String?
    /// The Music app's persistent ID, as the 16-digit hex string Music's scripting uses.
    var musicAppPersistentID: String?
    /// True when the song is in the library on this Mac.
    var isInLibrary: Bool
    var title: String?
    var artistName: String?
    var albumTitle: String?

    init(
        itemID: String,
        catalogID: String? = nil,
        cloudLibraryID: String? = nil,
        musicAppPersistentID: String? = nil,
        isInLibrary: Bool,
        title: String? = nil,
        artistName: String? = nil,
        albumTitle: String? = nil
    ) {
        self.itemID = itemID
        self.catalogID = catalogID
        self.cloudLibraryID = cloudLibraryID
        self.musicAppPersistentID = musicAppPersistentID
        self.isInLibrary = isInLibrary
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
    }

    /// Every ID this song may be shown under, for matching it in later library reads.
    var matchKeys: Set<String> {
        Set([itemID, catalogID, cloudLibraryID, musicKitPersistentID].compactMap { $0 })
    }

    /// The persistent ID the way MusicKit shows it inside a library playlist: a signed decimal.
    var musicKitPersistentID: String? {
        musicAppPersistentID.flatMap { UInt64($0, radix: 16) }.map { String(Int64(bitPattern: $0)) }
    }

    /// How the Music app finds this song: its persistent ID when known, otherwise its title,
    /// artist and album (a song added through Apple Music seconds ago has no persistent ID here yet).
    var musicAppMatch: MusicAppTrackMatch? {
        if let musicAppPersistentID {
            return .persistentID(musicAppPersistentID)
        }
        guard let title, !title.isEmpty else { return nil }
        return .metadata(name: title, artist: artistName ?? "", album: albumTitle)
    }

    /// The song as the Apple Music API names it in a playlist's track list.
    var cloudSong: AppleMusicCloudSong? {
        if let catalogID {
            return AppleMusicCloudSong(id: catalogID, kind: .catalog)
        }
        if let cloudLibraryID {
            return AppleMusicCloudSong(id: cloudLibraryID, kind: .library)
        }
        return nil
    }
}

/// An album with what saving and removing it needs.
struct AppleMusicAlbumReference: Equatable, Sendable {
    let itemID: String
    var catalogID: String?
    var isInLibrary: Bool
    /// The album's songs in the library on this Mac; removing the album removes these.
    var librarySongs: [AppleMusicSongReference]
}

/// A library playlist with what the two routes need to find it.
struct AppleMusicPlaylistReference: Equatable, Sendable {
    let itemID: String
    let name: String
    /// The Music app's persistent ID (hex), unknown for a playlist created through Apple Music
    /// that has not reached this Mac's library yet.
    var musicAppPersistentID: String?
}

/// Reads the library on this Mac to resolve the IDs above. `MusicKitLibraryLookup` is the live one.
protocol AppleMusicLibraryLookup: Sendable {
    /// One reference per ID, in order. IDs that are not in the library come back with
    /// `isInLibrary == false` and, when they look like catalog IDs, their catalog ID.
    func songs(ids: [String]) async throws -> [AppleMusicSongReference]
    /// Catalog songs mapped for display, for showing a just-saved song before the library has it.
    func catalogTracks(ids: [String]) async throws -> [MusicTrack]
    func albums(ids: [String]) async throws -> [AppleMusicAlbumReference]
    /// The library playlist with this ID, or `nil`.
    func playlist(id: String) async throws -> AppleMusicPlaylistReference?
}

/// Library edits for Apple Music, over two routes:
///
/// 1. **The Apple Music API** through MusicKit (`MusicDataRequest`, signed with the developer and
///    user token by MusicKit): saving songs and albums, creating playlists, adding songs to a
///    playlist, and the love rating that goes with a like. MusicKit's own library is read-only on
///    macOS, and the API has nothing for the rest.
/// 2. **The Music app on this Mac, through Apple Events**: removing songs from the library and
///    from playlists, renaming and deleting playlists. That costs the one-time "Spotiglass wants
///    to control Music" prompt.
///
/// Both change the user's iCloud Music Library, so the change reaches their other devices. The
/// library MusicKit reads on this Mac catches up later, so every edit is also recorded in
/// `AppleMusicPendingLibraryEdits`, which the provider lays over its reads until the library
/// shows the change.
struct AppleMusicLibraryEditor: Sendable {
    let lookup: any AppleMusicLibraryLookup
    let cloud: any AppleMusicCloudLibrary
    let musicApp: any MusicAppLibraryControlling
    let pending: AppleMusicPendingLibraryEdits
    /// Where playlist reads record the songs MusicKit lists under a persistent ID.
    let songReferences: AppleMusicSongReferenceRegistry

    init(
        lookup: any AppleMusicLibraryLookup = MusicKitLibraryLookup(),
        cloud: any AppleMusicCloudLibrary = MusicDataRequestCloudLibrary(),
        musicApp: any MusicAppLibraryControlling = MusicAppLibraryScripting(),
        pending: AppleMusicPendingLibraryEdits = .shared,
        songReferences: AppleMusicSongReferenceRegistry = .shared
    ) {
        self.lookup = lookup
        self.cloud = cloud
        self.musicApp = musicApp
        self.pending = pending
        self.songReferences = songReferences
    }

    // MARK: - Songs (Liked Songs)

    /// Liked Songs in Apple Music mode are the songs in the library, so a like saves the song to
    /// the library and loves it, the way the Music app's Favorite does.
    func saveSongs(ids: [String]) async throws {
        let references = try await lookup.songs(ids: ids)
        let toAdd = references.filter { !$0.isInLibrary && !pending.isSaved($0.matchKeys) }
        let catalogIDs = toAdd.compactMap(\.catalogID)
        guard !references.isEmpty, references.allSatisfy({ $0.isInLibrary || $0.catalogID != nil }) else {
            throw AppleMusicLibraryEditError.notEditable
        }
        if !catalogIDs.isEmpty {
            try await cloud.addToLibrary(songCatalogIDs: catalogIDs, albumCatalogIDs: [])
            let tracks = (try? await lookup.catalogTracks(ids: catalogIDs)) ?? []
            let tracksByID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for reference in toAdd {
                pending.recordSavedSong(reference.catalogID.flatMap { tracksByID[$0] }, reference: reference)
            }
        }
        for reference in references {
            pending.forgetRemovedSong(reference.matchKeys)
            // The love rating is a nicety on top of the save; a failed rating does not undo it.
            try? await rate(reference, .love)
        }
    }

    /// Removes songs from the library through the Music app and clears the love a like gave them.
    func removeSongs(ids: [String]) async throws {
        let references = try await lookup.songs(ids: ids).map(withPendingDetails)
        let matches = references.compactMap(\.musicAppMatch)
        guard matches.count == references.count, !matches.isEmpty else {
            throw AppleMusicLibraryEditError.notInMusicYet
        }
        try await musicApp.removeFromLibrary(matches)
        for reference in references {
            pending.recordRemovedSong(reference.matchKeys)
            try? await rate(reference, nil)
        }
    }

    /// Whether each song is in the library, counting edits the library has not caught up with.
    func songStatuses(ids: [String]) async throws -> [Bool] {
        let references = try await lookup.songs(ids: ids)
        return references.map { reference in
            if pending.isRemoved(reference.matchKeys) { return false }
            return reference.isInLibrary || pending.isSaved(reference.matchKeys)
        }
    }

    // MARK: - Albums

    func saveAlbums(ids: [String]) async throws {
        let references = try await lookup.albums(ids: ids)
        let catalogIDs = references.filter { !$0.isInLibrary || pending.isRemovedAlbum($0.itemID) }
            .compactMap(\.catalogID)
        if !catalogIDs.isEmpty {
            try await cloud.addToLibrary(songCatalogIDs: [], albumCatalogIDs: catalogIDs)
        } else if references.contains(where: { !$0.isInLibrary }) {
            throw AppleMusicLibraryEditError.notEditable
        }
        for reference in references {
            pending.recordSavedAlbum(reference.itemID)
        }
    }

    /// Removes the album's songs from the library through the Music app.
    func removeAlbums(ids: [String]) async throws {
        let references = try await lookup.albums(ids: ids)
        let songs = references.flatMap(\.librarySongs)
        let matches = songs.compactMap(\.musicAppMatch)
        guard !matches.isEmpty else {
            throw AppleMusicLibraryEditError.notInMusicYet
        }
        try await musicApp.removeFromLibrary(matches)
        for song in songs {
            pending.recordRemovedSong(song.matchKeys)
        }
        for reference in references {
            pending.recordRemovedAlbum(reference.itemID)
        }
    }

    func albumStatuses(ids: [String]) async throws -> [Bool] {
        try await lookup.albums(ids: ids).map { reference in
            if pending.isRemovedAlbum(reference.itemID) { return false }
            return reference.isInLibrary || pending.isSavedAlbum(reference.itemID)
        }
    }

    // MARK: - Playlists

    /// Creates an empty library playlist through the Apple Music API. Its ID is the cloud
    /// library ID (`p.…`) until the library on this Mac has it.
    func createPlaylist(name: String, ownerName: String) async throws -> MusicPlaylistSummary {
        let id = try await cloud.createPlaylist(name: name)
        let summary = MusicPlaylistSummary(
            id: id,
            name: name,
            ownerID: AppleMusicBrowsingProvider.libraryUserID,
            ownerName: ownerName,
            imageURL: nil,
            trackCount: 0,
            snapshotID: AppleMusicItemMapping.playlistSnapshotID
        )
        pending.recordCreatedPlaylist(summary)
        return summary
    }

    /// Adds songs to a library playlist through the Apple Music API.
    func addToPlaylist(playlistID: String, songIDs: [String]) async throws {
        let references = try await lookup.songs(ids: songIDs).map(withPendingDetails)
        let songs = references.compactMap(\.cloudSong)
        guard !songs.isEmpty, songs.count == references.count else {
            throw AppleMusicLibraryEditError.notEditable
        }
        let cloudID = try await cloudPlaylistID(for: playlistID)
        try await cloud.addToPlaylist(cloudPlaylistID: cloudID, songs: songs)
        let tracks = (try? await lookup.catalogTracks(ids: references.compactMap(\.catalogID))) ?? []
        let tracksByCatalogID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for reference in references {
            guard let catalogID = reference.catalogID, let track = tracksByCatalogID[catalogID] else { continue }
            pending.recordPlaylistAddition(track, reference: reference, playlistID: playlistID)
        }
    }

    /// Removes the given occurrences of songs from a playlist through the Music app.
    /// `positions` are zero-based, as the browser lists them.
    /// `shownCounts` says how often the playlist lists each song before the edit.
    func removeFromPlaylist(
        playlistID: String,
        removals: [(songID: String, positions: [Int])],
        shownCounts: [Int]
    ) async throws {
        let references = try await lookup.songs(ids: removals.map(\.songID)).map(withPendingDetails)
        var scripted: [MusicAppPlaylistRemoval] = []
        for (reference, removal) in zip(references, removals) {
            guard let match = reference.musicAppMatch else {
                throw AppleMusicLibraryEditError.notInMusicYet
            }
            scripted.append(MusicAppPlaylistRemoval(track: match, positions: removal.positions))
        }
        guard !scripted.isEmpty else { return }
        try await musicApp.removeFromPlaylist(try await musicAppPlaylist(for: playlistID), removals: scripted)
        for (index, (reference, removal)) in zip(references, removals).enumerated() {
            pending.recordPlaylistRemoval(
                reference.matchKeys,
                removed: removal.positions.count,
                shownBefore: index < shownCounts.count ? shownCounts[index] : removal.positions.count,
                playlistID: playlistID
            )
        }
    }

    func renamePlaylist(playlistID: String, name: String) async throws {
        try await musicApp.renamePlaylist(try await musicAppPlaylist(for: playlistID), to: name)
        pending.recordRenamedPlaylist(playlistID, name: name)
    }

    func deletePlaylist(playlistID: String) async throws {
        try await musicApp.deletePlaylist(try await musicAppPlaylist(for: playlistID))
        pending.recordDeletedPlaylist(playlistID)
    }

    /// The songs of a playlist created through Apple Music that the library on this Mac does
    /// not show yet, read back from the API.
    func cloudPlaylistTracks(playlistID: String) async throws -> [Song]? {
        guard Self.isCloudPlaylistID(playlistID) else { return nil }
        return try await cloud.playlistTracks(cloudPlaylistID: playlistID)
    }

    // MARK: - Helpers

    static func isCloudPlaylistID(_ id: String) -> Bool {
        id.hasPrefix("p.")
    }

    /// MusicKit shows a library item under the Music app's persistent ID as a signed decimal;
    /// Music's scripting wants the same 64 bits as 16 hex digits.
    static func musicAppPersistentID(fromMusicKitID id: String) -> String? {
        guard let value = Int64(id) else { return nil }
        return String(format: "%016llX", UInt64(bitPattern: value))
    }

    /// A song saved moments ago is not in the library on this Mac yet; the pending edit still
    /// knows its title, artist and album, which is how the Music app finds it.
    private func withPendingDetails(_ reference: AppleMusicSongReference) -> AppleMusicSongReference {
        guard reference.musicAppPersistentID == nil, reference.title == nil,
              let track = pending.savedTrack(matching: reference.matchKeys)
        else { return reference }
        var detailed = reference
        detailed.title = track.name
        detailed.artistName = track.artists.first
        detailed.albumTitle = track.albumName
        return detailed
    }

    private func rate(_ reference: AppleMusicSongReference, _ rating: AppleMusicRating?) async throws {
        if let catalogID = reference.catalogID {
            try await cloud.setRating(rating, songID: catalogID, isLibraryID: false)
        } else if let cloudLibraryID = reference.cloudLibraryID {
            try await cloud.setRating(rating, songID: cloudLibraryID, isLibraryID: true)
        }
    }

    /// The API names playlists by cloud library ID (`p.…`), MusicKit on macOS by persistent ID.
    /// Nothing maps one to the other, so a playlist from the library is found among the
    /// user's editable cloud playlists by its name, which must be unique.
    private func cloudPlaylistID(for playlistID: String) async throws -> String {
        if Self.isCloudPlaylistID(playlistID) { return playlistID }
        guard let playlist = try await lookup.playlist(id: playlistID) else {
            throw AppleMusicLibraryEditError.notEditable
        }
        let name = pending.renamedName(for: playlistID) ?? playlist.name
        let matches = try await cloud.editablePlaylists().filter { $0.name == name }
        guard matches.count <= 1 else { throw AppleMusicLibraryEditError.ambiguousPlaylist }
        guard let match = matches.first else { throw AppleMusicLibraryEditError.notEditable }
        return match.id
    }

    /// The Music app finds a library playlist by persistent ID; one created through Apple Music
    /// moments ago only by its name.
    private func musicAppPlaylist(for playlistID: String) async throws -> MusicAppPlaylistMatch {
        if let persistentID = Self.musicAppPersistentID(fromMusicKitID: playlistID) {
            return .persistentID(persistentID)
        }
        if let playlist = try await lookup.playlist(id: playlistID), let persistentID = playlist.musicAppPersistentID {
            return .persistentID(persistentID)
        }
        guard let name = pending.renamedName(for: playlistID) ?? pending.createdPlaylist(id: playlistID)?.name else {
            throw AppleMusicLibraryEditError.notEditable
        }
        return .name(name)
    }
}
