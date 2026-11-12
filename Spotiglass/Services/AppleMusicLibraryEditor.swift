import Foundation
import MusicKit

/// Why an Apple Music library edit did not happen. Every case reads as one calm line, because
/// the browser shows `localizedDescription` as its toast.
enum AppleMusicLibraryEditError: LocalizedError, Equatable {
    /// The user said no to "Spotiglass wants to control Music" (or has not answered yet).
    case musicControlDenied
    /// The Music app did not start or did not answer.
    case musicUnavailable
    /// A change answered late and Music still didn't answer after a long wait, so the change
    /// may still go through (#411).
    case musicStillBusy
    /// The item was changed through Apple Music moments ago and the Music app on this Mac has not
    /// received it yet, so Music can't find it to change it again.
    case notInMusicYet
    /// Two editable playlists share the name Apple Music needs to tell them apart.
    case ambiguousPlaylist
    /// More than one song in the library matches (a duplicate copy), so Music can't tell which to remove.
    case ambiguousSong
    /// Neither route can change this item (a song without an Apple Music ID, Apple's own playlists).
    case notEditable
    /// Apple Music answered with an error.
    case requestFailed
    /// Music lists the playlist differently than Spotiglass shows it: it changed elsewhere since
    /// it was read, so a new order counted from the screen would move the wrong songs (#543).
    case playlistChanged

    var errorDescription: String? {
        switch self {
        case .musicControlDenied:
            SpotiglassL10n.string("appleMusic.edit.error.musicControlDenied")
        case .musicUnavailable:
            SpotiglassL10n.string("appleMusic.edit.error.musicUnavailable")
        case .musicStillBusy:
            SpotiglassL10n.string("appleMusic.edit.error.musicStillBusy")
        case .notInMusicYet:
            SpotiglassL10n.string("appleMusic.edit.error.notInMusicYet")
        case .ambiguousPlaylist:
            SpotiglassL10n.string("appleMusic.edit.error.ambiguousPlaylist")
        case .ambiguousSong:
            SpotiglassL10n.string("appleMusic.edit.error.ambiguousSong")
        case .notEditable:
            SpotiglassL10n.string("appleMusic.edit.error.notEditable")
        case .requestFailed:
            SpotiglassL10n.string("appleMusic.edit.error.requestFailed")
        case .playlistChanged:
            SpotiglassL10n.string("playlist.mutation.reorderChangedElsewhere")
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
    /// The Music app's persistent ID (hex) of the playlist the song was listed in, when it was.
    var sourcePlaylistPersistentID: String?
    /// The row as the browser listed it, for a song only the Music app can add: it then shows in
    /// the playlist it was added to before the library lists it there.
    var shownTrack: MusicTrack?
    /// When Spotiglass saved the song, for a song the Music app may not list under its persistent
    /// ID yet: the Music app then only matches tracks it added since.
    var savedAt: Date?

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
        return .metadata(name: title, artist: artistName ?? "", album: albumTitle, addedSince: savedAt)
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
    /// The songs of catalog albums, mapped for display, for showing a just-saved album's songs
    /// in Liked Songs before the library has them.
    func catalogAlbumTracks(albumIDs: [String]) async throws -> [MusicTrack]
    func albums(ids: [String]) async throws -> [AppleMusicAlbumReference]
    /// The library playlist with this ID, or `nil`.
    func playlist(id: String) async throws -> AppleMusicPlaylistReference?
    /// The IDs MusicKit keeps for a song it lists only under its persistent ID (a playlist row),
    /// found among the library's songs; `nil` when there is none.
    func libraryIdentity(of reference: AppleMusicSongReference) async throws -> AppleMusicSongIdentity?
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
        // A song removed moments ago can still read as in the library on this Mac; it needs the
        // save as much as one that never was.
        let needsSave: (AppleMusicSongReference) -> Bool = { reference in
            (!reference.isInLibrary || pending.isRemoved(reference.matchKeys)) && !pending.isSaved(reference.matchKeys)
        }
        var references: [AppleMusicSongReference] = []
        for reference in try await lookup.songs(ids: ids) {
            references.append(needsSave(reference) ? try await withLibraryIDs(reference) : reference)
        }
        let toAdd = references.filter(needsSave)
        let catalogIDs = toAdd.compactMap(\.catalogID)
        guard !references.isEmpty, references.allSatisfy({ !needsSave($0) || $0.catalogID != nil }) else {
            throw AppleMusicLibraryEditError.notEditable
        }
        if !catalogIDs.isEmpty {
            let requestedAt = Date()
            try await cloud.addToLibrary(songCatalogIDs: catalogIDs, albumCatalogIDs: [])
            let tracks = (try? await lookup.catalogTracks(ids: catalogIDs)) ?? []
            let tracksByID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for reference in toAdd {
                pending.recordSavedSong(
                    reference.catalogID.flatMap { tracksByID[$0] },
                    reference: reference,
                    requestedAt: requestedAt
                )
            }
        }
        for reference in references {
            pending.forgetRemovedSong(reference.matchKeys)
            rememberLibraryState(of: reference, isInLibrary: true)
            // The love rating is a nicety on top of the save; a failed rating does not undo it.
            try? await rate(reference, .love)
        }
    }

    /// Removes songs from the library through the Music app and clears the love a like gave them.
    func removeSongs(ids: [String]) async throws {
        var references: [AppleMusicSongReference] = []
        for reference in try await lookup.songs(ids: ids).map(withPendingDetails) {
            // A row listed only under its persistent ID (a song liked from a playlist moments
            // ago) needs its catalog ID to clear the love and to end the like everywhere (#401).
            references.append((try? await withLibraryIDs(reference)) ?? reference)
        }
        let matches = references.compactMap(\.musicAppMatch)
        guard matches.count == references.count, !matches.isEmpty else {
            throw AppleMusicLibraryEditError.notInMusicYet
        }
        try await musicApp.removeFromLibrary(matches)
        for reference in references {
            pending.recordRemovedSong(reference.matchKeys)
            rememberLibraryState(of: reference, isInLibrary: false)
            try? await rate(reference, nil)
        }
    }

    /// A playlist or album row remembers whether its song was in the library when it was read;
    /// a like or unlike changes that, and the pending edit that covers it ends once the library
    /// shows the change, before the row is read again.
    private func rememberLibraryState(of reference: AppleMusicSongReference, isInLibrary: Bool) {
        songReferences.update(matching: reference.matchKeys) { listed in
            listed.isInLibrary = isInLibrary
            listed.catalogID = listed.catalogID ?? reference.catalogID
            listed.cloudLibraryID = listed.cloudLibraryID ?? reference.cloudLibraryID
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

    /// What is known about a song without reading the library: what the playlist or album read
    /// found for its row (a song can be in a playlist without being in the library, #401), else a
    /// song listed under a cloud library ID (`i.…`) is in the library, unless Spotiglass changed
    /// it moments ago. `nil` for a catalog ID or a persistent ID no read remembers (a row of a
    /// very long playlist can drop out of the registry), which only a lookup can answer.
    func knownSongStatus(id: String) -> Bool? {
        let keys = songReferences.reference(for: id)?.matchKeys ?? [id]
        if pending.isRemoved(keys) { return false }
        if pending.isSaved(keys) { return true }
        if let listed = songReferences.reference(for: id) { return listed.isInLibrary }
        return id.hasPrefix("i.") ? true : nil
    }

    // MARK: - Albums

    func saveAlbums(ids: [String]) async throws {
        let references = try await lookup.albums(ids: ids)
        let catalogIDs = references.filter { !$0.isInLibrary || pending.isRemovedAlbum($0.itemID) }
            .compactMap(\.catalogID)
        if !catalogIDs.isEmpty {
            let requestedAt = Date()
            try await cloud.addToLibrary(songCatalogIDs: [], albumCatalogIDs: catalogIDs)
            // Liked Songs are the library: the album's songs show there at once, in album order
            // (each pending save goes on top).
            for track in ((try? await lookup.catalogAlbumTracks(albumIDs: catalogIDs)) ?? []).reversed() {
                let reference = AppleMusicSongReference(itemID: track.id, catalogID: track.id, isInLibrary: false)
                pending.recordSavedSong(track, reference: reference, requestedAt: requestedAt)
                rememberLibraryState(of: reference, isInLibrary: true)
            }
        } else if references.contains(where: { !$0.isInLibrary }) {
            throw AppleMusicLibraryEditError.notEditable
        }
        for reference in references {
            pending.recordSavedAlbum(reference.itemID)
        }
    }

    /// Removes the album's songs from the library through the Music app. A song of the album that
    /// is only in a playlist isn't in the library, so Music couldn't find it there, unless it was
    /// liked moments ago.
    func removeAlbums(ids: [String]) async throws {
        let references = try await lookup.albums(ids: ids)
        // A song liked moments ago counts too: the library on this Mac just doesn't show it yet.
        let songs = references.flatMap(\.librarySongs).filter { $0.isInLibrary || pending.isSaved($0.matchKeys) }
        let matches = songs.compactMap(\.musicAppMatch)
        guard !matches.isEmpty else {
            throw AppleMusicLibraryEditError.notInMusicYet
        }
        try await musicApp.removeFromLibrary(matches)
        for song in songs {
            pending.recordRemovedSong(song.matchKeys)
            rememberLibraryState(of: song, isInLibrary: false)
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

    /// Creates a library playlist with these songs. It is one step on either route, so a song
    /// that can't be added leaves no empty playlist behind (#395):
    /// - Songs the Apple Music API knows (catalog or cloud library ID) go into the create request
    ///   itself. The playlist's ID is then its cloud library ID (`p.…`) until the library on this
    ///   Mac has it.
    /// - Library songs MusicKit shows only under a persistent ID go through the Music app, which
    ///   creates the playlist and deletes it again if a song can't be added. The ID is then the
    ///   new playlist's persistent ID, the way MusicKit shows it.
    /// `existingIDsWithSameName` are the playlists already called `name`; only a new one with
    /// that name ends the pending entry.
    func createPlaylist(
        name: String,
        ownerName: String,
        songIDs: [String] = [],
        existingIDsWithSameName: Set<String> = []
    ) async throws -> MusicPlaylistSummary {
        let references = try await songReferences(ids: songIDs)
        let id: String
        switch try Self.route(for: references) {
        case let .cloud(songs):
            id = try await cloud.createPlaylist(name: name, songs: songs)
        case let .musicApp(tracks):
            let persistentID = try await musicApp.createPlaylist(name: name, tracks: tracks)
            guard let value = UInt64(persistentID, radix: 16) else { throw AppleMusicLibraryEditError.requestFailed }
            id = String(Int64(bitPattern: value))
        }
        let summary = MusicPlaylistSummary(
            id: id,
            name: name,
            ownerID: AppleMusicBrowsingProvider.libraryUserID,
            ownerName: ownerName,
            imageURL: nil,
            trackCount: references.count,
            snapshotID: AppleMusicItemMapping.playlistSnapshotID
        )
        pending.recordCreatedPlaylist(summary, existingIDsWithSameName: existingIDsWithSameName)
        // Like an add, a new playlist puts its songs back into the library.
        for reference in references {
            pending.forgetRemovedSong(reference.matchKeys)
        }
        await recordAdditions(references, playlistID: id, shownTracks: [])
        return summary
    }

    /// Adds songs to a library playlist: through the Apple Music API when it knows every song,
    /// otherwise through the Music app (library songs MusicKit lists only under a persistent ID,
    /// #395). `shownTracks` is the playlist as the browser lists it before the edit, so a second
    /// copy of a song already in it stays shown until the library lists both.
    func addToPlaylist(playlistID: String, songIDs: [String], shownTracks: [MusicTrack] = []) async throws {
        let references = try await songReferences(ids: songIDs)
        guard !references.isEmpty else { throw AppleMusicLibraryEditError.notEditable }
        switch try Self.route(for: references) {
        case let .cloud(songs):
            let cloudID = try await cloudPlaylistID(for: playlistID)
            try await cloud.addToPlaylist(cloudPlaylistID: cloudID, songs: songs)
        case let .musicApp(tracks):
            try await musicApp.addToPlaylist(try await musicAppPlaylist(for: playlistID), tracks: tracks)
        }
        // Adding to a playlist puts the song back into the library.
        for reference in references {
            pending.forgetRemovedSong(reference.matchKeys)
        }
        pending.adjustCreatedPlaylistTrackCount(playlistID, by: references.count)
        await recordAdditions(references, playlistID: playlistID, shownTracks: shownTracks)
    }

    /// How a set of songs gets into a playlist. One route for all of them, so an edit never
    /// stops halfway between the two.
    enum PlaylistAddRoute: Equatable {
        case cloud([AppleMusicCloudSong])
        case musicApp([MusicAppTrackMatch])
    }

    static func route(for references: [AppleMusicSongReference]) throws -> PlaylistAddRoute {
        let songs = references.compactMap(\.cloudSong)
        if songs.count == references.count {
            return .cloud(songs)
        }
        // The Music app adds what its library has, or what the playlist it was listed in has.
        let tracks = references.compactMap { reference -> MusicAppTrackMatch? in
            if let persistentID = reference.musicAppPersistentID, let playlistID = reference.sourcePlaylistPersistentID {
                return .playlistEntry(persistentID: persistentID, playlistPersistentID: playlistID)
            }
            return reference.isInLibrary ? reference.musicAppMatch : nil
        }
        guard tracks.count == references.count else { throw AppleMusicLibraryEditError.notEditable }
        return .musicApp(tracks)
    }

    private func songReferences(ids: [String]) async throws -> [AppleMusicSongReference] {
        guard !ids.isEmpty else { return [] }
        return try await lookup.songs(ids: ids).map(withPendingDetails)
    }

    /// Lays the added songs over later reads of the playlist until the library lists them.
    private func recordAdditions(_ references: [AppleMusicSongReference], playlistID: String, shownTracks: [MusicTrack]) async {
        let catalogIDs = references.compactMap(\.catalogID)
        let tracks = catalogIDs.isEmpty ? [] : ((try? await lookup.catalogTracks(ids: catalogIDs)) ?? [])
        let tracksByCatalogID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for reference in references {
            // A song MusicKit lists only under a persistent ID has no catalog track; the row it
            // was listed as stands in for it.
            guard let track = reference.catalogID.flatMap({ tracksByCatalogID[$0] }) ?? reference.shownTrack else { continue }
            let metadataKey = AppleMusicPendingLibraryEdits.metadataKey(track)
            let shown = shownTracks.filter {
                reference.matchKeys.contains($0.id) || $0.id == track.id
                    || AppleMusicPendingLibraryEdits.metadataKey($0) == metadataKey
            }.count
            pending.recordPlaylistAddition(track, reference: reference, playlistID: playlistID, shownBefore: shown)
        }
    }

    /// Removes the given occurrences of songs from a playlist through the Music app.
    /// `positions` are zero-based, as the browser lists them. `shownTracks` is the playlist as
    /// the browser lists it before the edit (pending edits included), so the view hides the
    /// copies that were picked until the library shows the removal.
    func removeFromPlaylist(
        playlistID: String,
        removals: [(songID: String, positions: [Int])],
        shownTracks: [MusicTrack]
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
        pending.adjustCreatedPlaylistTrackCount(playlistID, by: -removals.reduce(0) { $0 + $1.positions.count })
        for (reference, removal) in zip(references, removals) {
            // A copy added from Spotiglass shows under another of the song's IDs than the
            // library's rows do: every one of them counts as the song.
            let isSong: (MusicTrack) -> Bool = { $0.id == removal.songID || reference.matchKeys.contains($0.id) }
            pending.recordPlaylistRemoval(
                reference.matchKeys,
                metadataKey: reference.title.map { AppleMusicPendingLibraryEdits.metadataKey(name: $0, artist: reference.artistName) },
                removed: removal.positions.count,
                shownBefore: shownTracks.filter(isSong).count,
                ordinals: removal.positions.filter { $0 < shownTracks.count }.map { position in
                    shownTracks[..<position].filter(isSong).count
                },
                playlistID: playlistID
            )
        }
    }

    /// Saves a new order through the Music app (#543): the Apple Music API has no reorder. Every
    /// row must be one Music knows by its persistent ID, as rows read from the library on this
    /// Mac are; a song added moments ago that the library doesn't list yet can't be placed.
    func reorderPlaylist(playlistID: String, reorder: MusicPlaylistReorder) async throws {
        let moves = PlaylistTrackReorder.moveToEndSequence(for: reorder.order)
        guard !moves.isEmpty else { return }
        // Songs added or removed through Apple Music moments ago are shown before Music lists
        // them (an added one under its catalog ID, which reads like a persistent ID): Music's
        // playlist can't match the screen until the library has them.
        guard !pending.hasPendingTracks(playlistID: playlistID) else {
            throw AppleMusicLibraryEditError.notInMusicYet
        }
        let expected = try reorder.currentTrackIDs.map { id -> String in
            guard let id, let persistentID = Self.musicAppPersistentID(fromMusicKitID: id) else {
                throw AppleMusicLibraryEditError.notInMusicYet
            }
            return persistentID
        }
        // Music not finding the playlist yet (synced moments ago) is not Music refusing it as one
        // it can't edit (a smart playlist): the browser stops offering dragging only for that.
        let playlist: MusicAppPlaylistMatch
        do {
            playlist = try await musicAppPlaylist(for: playlistID)
        } catch AppleMusicLibraryEditError.notEditable {
            throw AppleMusicLibraryEditError.notInMusicYet
        }
        try await musicApp.reorderPlaylist(playlist, expectedPersistentIDs: expected, moveToEnd: moves)
    }

    func renamePlaylist(playlistID: String, name: String) async throws {
        // Learn the cloud ID while the old name still finds it; adds after the rename use it.
        if !Self.isCloudPlaylistID(playlistID), pending.cloudPlaylistID(for: playlistID) == nil {
            _ = try? await cloudPlaylistID(for: playlistID)
        }
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

    /// Playlist names compared the way AppleScript compares them in Music: case is ignored, so
    /// "Mix" and "mix" are the same name to the script.
    static func isSamePlaylistName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: .caseInsensitive) == .orderedSame
    }

    static func isCloudPlaylistID(_ id: String) -> Bool {
        id.hasPrefix("p.")
    }

    /// MusicKit shows a library item under the Music app's persistent ID as a signed decimal;
    /// Music's scripting wants the same 64 bits as 16 hex digits.
    static func musicAppPersistentID(fromMusicKitID id: String) -> String? {
        guard let value = Int64(id) else { return nil }
        return String(format: "%016llX", UInt64(bitPattern: value))
    }

    /// A playlist row MusicKit lists only under its persistent ID has no catalog ID, which a save
    /// needs; the song's library entry has it (#401).
    private func withLibraryIDs(_ reference: AppleMusicSongReference) async throws -> AppleMusicSongReference {
        guard reference.catalogID == nil, let identity = try await lookup.libraryIdentity(of: reference) else {
            return reference
        }
        var detailed = reference
        detailed.catalogID = identity.catalogID
        detailed.cloudLibraryID = reference.cloudLibraryID ?? identity.cloudLibraryID
        return detailed
    }

    /// A song saved moments ago is not in the library on this Mac yet; the pending edit still
    /// knows its title, artist and album, which is how the Music app finds it.
    private func withPendingDetails(_ reference: AppleMusicSongReference) -> AppleMusicSongReference {
        guard reference.musicAppPersistentID == nil, reference.title == nil,
              let saved = pending.savedSong(matching: reference.matchKeys), let track = saved.track
        else { return reference }
        var detailed = reference
        detailed.title = track.name
        detailed.artistName = track.artists.first
        detailed.albumTitle = track.albumName
        detailed.savedAt = saved.at
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
    /// user's editable cloud playlists by its name, which must be unique. A match is remembered,
    /// so a later rename can't send the edit to another playlist with the new name.
    private func cloudPlaylistID(for playlistID: String) async throws -> String {
        if Self.isCloudPlaylistID(playlistID) { return playlistID }
        if let known = pending.cloudPlaylistID(for: playlistID) { return known }
        let listedName: String
        let createdMomentsAgo: Bool
        if let playlist = try await lookup.playlist(id: playlistID) {
            listedName = playlist.name
            createdMomentsAgo = false
        } else if let created = pending.createdPlaylist(id: playlistID) {
            // Created through the Music app moments ago: this Mac's library doesn't list it yet,
            // the cloud may already. Only its name can find it there, and only without a namesake.
            guard pending.existingIDsWithSameName(asCreated: playlistID).isEmpty else {
                throw AppleMusicLibraryEditError.ambiguousPlaylist
            }
            // Renamed since: an older playlist may already have the new name, and the cloud list
            // can't tell the two apart. Wait until this Mac lists it under its own ID.
            guard pending.renamedName(for: playlistID) == nil else {
                throw AppleMusicLibraryEditError.notInMusicYet
            }
            listedName = created.nameAsSent
            createdMomentsAgo = true
        } else {
            throw AppleMusicLibraryEditError.notEditable
        }
        let editable = try await cloud.editablePlaylists()
        let renamed = pending.renamedName(for: playlistID)
        // Renamed moments ago and the cloud list still shows the old name: the new name may
        // belong to another playlist there, so wait instead of guessing.
        if let renamed, !Self.isSamePlaylistName(renamed, listedName),
           editable.contains(where: { Self.isSamePlaylistName($0.name, listedName) }) {
            throw AppleMusicLibraryEditError.notInMusicYet
        }
        let matches = editable.filter { Self.isSamePlaylistName($0.name, renamed ?? listedName) }
        guard matches.count <= 1 else { throw AppleMusicLibraryEditError.ambiguousPlaylist }
        guard let match = matches.first else {
            throw createdMomentsAgo ? AppleMusicLibraryEditError.notInMusicYet : AppleMusicLibraryEditError.notEditable
        }
        pending.recordCloudPlaylistID(match.id, for: playlistID)
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
        guard let name = pending.renamedName(for: playlistID) ?? pending.createdPlaylist(id: playlistID)?.nameAsSent else {
            throw AppleMusicLibraryEditError.notEditable
        }
        // Music finds this playlist only by name. If another playlist has the name, the one Music
        // finds may be that one, so the edit stops instead.
        let namesakeAtCreate = pending.createdPlaylist(id: playlistID).map { Self.isSamePlaylistName($0.nameAsSent, name) } == true
            && !pending.existingIDsWithSameName(asCreated: playlistID).isEmpty
        let namesakeInCloud = try await cloud.editablePlaylists().contains {
            Self.isSamePlaylistName($0.name, name) && $0.id != playlistID
        }
        if namesakeAtCreate || namesakeInCloud {
            throw AppleMusicLibraryEditError.ambiguousPlaylist
        }
        return .name(name)
    }
}
