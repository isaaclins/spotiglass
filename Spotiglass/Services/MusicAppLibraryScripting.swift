import Foundation

/// How the Music app finds a track.
enum MusicAppTrackMatch: Equatable, Sendable {
    /// Music's own persistent ID, 16 hex digits.
    case persistentID(String)
    /// Title, artist and album, for a song added through Apple Music moments ago that this Mac
    /// does not know the persistent ID of yet. `addedSince`, when set, limits it to tracks Music
    /// added after that moment, so an older song with the same details is never the one changed.
    case metadata(name: String, artist: String, album: String?, addedSince: Date? = nil)
    /// A song listed in a playlist. Music finds it in the library, or else in that playlist: a
    /// song from Apple Music that is in a playlist but not in the library is only there (#395).
    /// Only adds use it; nothing is ever removed through the playlist it was found in.
    case playlistEntry(persistentID: String, playlistPersistentID: String)
}

/// How the Music app finds a playlist.
enum MusicAppPlaylistMatch: Equatable, Sendable {
    case persistentID(String)
    /// Only for a playlist created through Apple Music moments ago.
    case name(String)
}

/// Some occurrences of one track in a playlist, by zero-based position.
struct MusicAppPlaylistRemoval: Equatable, Sendable {
    let track: MusicAppTrackMatch
    let positions: [Int]
}

/// The library edits only the Music app can make. `MusicAppLibraryScripting` is the live one.
protocol MusicAppLibraryControlling: Sendable {
    func removeFromLibrary(_ tracks: [MusicAppTrackMatch]) async throws
    func removeFromPlaylist(_ playlist: MusicAppPlaylistMatch, removals: [MusicAppPlaylistRemoval]) async throws
    func renamePlaylist(_ playlist: MusicAppPlaylistMatch, to name: String) async throws
    func deletePlaylist(_ playlist: MusicAppPlaylistMatch) async throws
    /// Adds library tracks to a playlist, for songs the Apple Music API has no ID for (a song
    /// MusicKit lists only under its persistent ID).
    func addToPlaylist(_ playlist: MusicAppPlaylistMatch, tracks: [MusicAppTrackMatch]) async throws
    /// Creates a playlist with these library tracks and returns its persistent ID (16 hex
    /// digits). Nothing is left behind when a track can't be added.
    func createPlaylist(name: String, tracks: [MusicAppTrackMatch]) async throws -> String
}

/// Runs one AppleScript against the Music app. Separate from the script text so tests check
/// the scripts without the Music app.
protocol MusicAppScriptRunning: Sendable {
    /// The script's result as text, when it returns one.
    @discardableResult
    func run(_ source: String) async throws -> String?
}

/// Library edits through the Music app on this Mac, as AppleScript sent over Apple Events.
///
/// The scripts look everything up before they change anything, so a song or playlist Music
/// can't find stops the whole edit instead of leaving half of it done.
struct MusicAppLibraryScripting: MusicAppLibraryControlling {
    let runner: any MusicAppScriptRunning

    init(runner: any MusicAppScriptRunning = AppleEventMusicAppScriptRunner()) {
        self.runner = runner
    }

    func removeFromLibrary(_ tracks: [MusicAppTrackMatch]) async throws {
        guard !tracks.isEmpty else { return }
        try await runner.run(MusicAppScripts.removeFromLibrary(tracks))
    }

    func removeFromPlaylist(_ playlist: MusicAppPlaylistMatch, removals: [MusicAppPlaylistRemoval]) async throws {
        guard removals.contains(where: { !$0.positions.isEmpty }) else { return }
        try await runner.run(MusicAppScripts.removeFromPlaylist(playlist, removals: removals))
    }

    func renamePlaylist(_ playlist: MusicAppPlaylistMatch, to name: String) async throws {
        try await runner.run(MusicAppScripts.renamePlaylist(playlist, to: name))
    }

    func deletePlaylist(_ playlist: MusicAppPlaylistMatch) async throws {
        try await runner.run(MusicAppScripts.deletePlaylist(playlist))
    }

    func addToPlaylist(_ playlist: MusicAppPlaylistMatch, tracks: [MusicAppTrackMatch]) async throws {
        guard !tracks.isEmpty else { return }
        try await runner.run(MusicAppScripts.addToPlaylist(playlist, tracks: tracks))
    }

    func createPlaylist(name: String, tracks: [MusicAppTrackMatch]) async throws -> String {
        let result = try await runner.run(MusicAppScripts.createPlaylist(name: name, tracks: tracks))
        guard let id = result?.trimmingCharacters(in: .whitespacesAndNewlines), UInt64(id, radix: 16) != nil else {
            throw AppleMusicLibraryEditError.requestFailed
        }
        return id
    }
}

/// The AppleScript sources. Script errors 9001 to 9004 carry the outcomes the editor reports.
enum MusicAppScripts {
    static let notFoundError = 9001
    static let ambiguousError = 9002
    static let notEditableError = 9003
    static let ambiguousSongError = 9004
    /// Slack before the save request for Music's `date added` (the server's clock against this
    /// Mac's). Kept to seconds: a song added before it with the same details must never match.
    static let addedSinceMarginSeconds = 5

    static func removeFromLibrary(_ tracks: [MusicAppTrackMatch], now: Date = Date()) -> String {
        var lines = [scriptNowLine, "tell application \"Music\"", "set lib to library playlist 1", "set targets to {}"]
        for track in tracks {
            lines += cutoffLines(track, now: now) + [
                "set found to (every track of lib whose \(condition(track)))",
                "if (count of found) is 0 then error \"not found\" number \(notFoundError)",
                "if (count of found) is greater than 1 then error \"ambiguous\" number \(ambiguousSongError)",
                "set end of targets to item 1 of found",
            ]
        }
        lines += ["repeat with target in targets", "delete target", "end repeat", "end tell"]
        return lines.joined(separator: "\n")
    }

    /// Finds every occurrence first and deletes only once all of them are found, so a song that
    /// is gone already stops the edit before anything is removed. An occurrence is the track at
    /// its position; when that is no longer the expected track (the playlist changed elsewhere),
    /// it is the first matching track not already picked. Deletes go by the entries' IDs, from
    /// the last position to the first.
    static func removeFromPlaylist(
        _ playlist: MusicAppPlaylistMatch,
        removals: [MusicAppPlaylistRemoval],
        now: Date = Date()
    ) -> String {
        let entries = removals
            .flatMap { removal in removal.positions.map { (position: $0, track: removal.track) } }
            .sorted { $0.position > $1.position }
        var lines = [scriptNowLine, "tell application \"Music\""] + findPlaylist(playlist) + ["set targetIDs to {}"]
        for entry in entries {
            let index = entry.position + 1
            lines += cutoffLines(entry.track, now: now) + [
                "set picked to missing value",
                "if \(index) is less than or equal to (count of tracks of pl) then",
                "set t to track \(index) of pl",
                "if (\(condition(entry.track, of: "t"))) and (targetIDs does not contain (id of t)) then set picked to id of t",
                "end if",
                "if picked is missing value then",
                "repeat with candidate in (every track of pl whose \(condition(entry.track)))",
                "if targetIDs does not contain (id of candidate) then",
                "set picked to id of candidate",
                "exit repeat",
                "end if",
                "end repeat",
                "end if",
                "if picked is missing value then error \"not found\" number \(notFoundError)",
                "set end of targetIDs to picked",
            ]
        }
        lines += [
            "repeat with targetID in targetIDs",
            "delete (every track of pl whose id is (contents of targetID))",
            "end repeat",
            "end tell",
        ]
        return lines.joined(separator: "\n")
    }

    /// Finds every track first, then adds them in order, so a song Music can't find stops the
    /// edit before anything is added. When an add fails partway, the songs this script already
    /// appended are taken out of the playlist again, so the edit is all or nothing. Only entries
    /// past the playlist's old end whose persistent ID this script added go, once per add: a
    /// song another device appended meanwhile stays, and nothing leaves the library.
    static func addToPlaylist(_ playlist: MusicAppPlaylistMatch, tracks: [MusicAppTrackMatch], now: Date = Date()) -> String {
        var lines = [scriptNowLine, "tell application \"Music\""] + findPlaylist(playlist)
        lines += findTracks(tracks, now: now)
        lines += [
            "set countBefore to (count of tracks of pl)",
            "set addedIDs to {}",
            "try",
            "repeat with songItem in pickedSongs",
            "set end of addedIDs to (persistent ID of (contents of songItem))",
            "duplicate (contents of songItem) to pl",
            "end repeat",
            "on error errorMessage number errorNumber",
            "repeat with i from (count of tracks of pl) to (countBefore + 1) by -1",
            "set entryID to persistent ID of track i of pl",
            "if addedIDs contains entryID then",
            "delete track i of pl",
            "set keptIDs to {}",
            "set dropped to false",
            "repeat with addedID in addedIDs",
            "if (not dropped) and ((contents of addedID) is entryID) then",
            "set dropped to true",
            "else",
            "set end of keptIDs to (contents of addedID)",
            "end if",
            "end repeat",
            "set addedIDs to keptIDs",
            "end if",
            "end repeat",
            "error errorMessage number errorNumber",
            "end try",
            "end tell",
        ]
        return lines.joined(separator: "\n")
    }

    /// Finds every track before the playlist exists, and deletes the new playlist again when a
    /// track can't be added, so a failed edit leaves no empty playlist behind (#395). Returns the
    /// new playlist's persistent ID.
    static func createPlaylist(name: String, tracks: [MusicAppTrackMatch], now: Date = Date()) -> String {
        var lines = [scriptNowLine, "tell application \"Music\""] + findTracks(tracks, now: now)
        lines += [
            "set pl to make new user playlist with properties {name:\(quoted(name))}",
            "try",
            "repeat with songItem in pickedSongs",
            "duplicate (contents of songItem) to pl",
            "end repeat",
            "on error errorMessage number errorNumber",
            "delete pl",
            "error errorMessage number errorNumber",
            "end try",
            "return persistent ID of pl",
            "end tell",
        ]
        return lines.joined(separator: "\n")
    }

    /// Wraps a script so each Apple Event it sends gives up after `seconds` instead of
    /// AppleScript's default of two minutes; the script then fails with errAETimeout.
    static func withTimeout(_ source: String, seconds: Int) -> String {
        "with timeout of \(seconds) seconds\n\(source)\nend timeout"
    }

    /// Sets `pickedSongs` to one library track per match, in order.
    private static func findTracks(_ tracks: [MusicAppTrackMatch], now: Date) -> [String] {
        var lines = ["set lib to library playlist 1", "set pickedSongs to {}"]
        for track in tracks {
            lines += cutoffLines(track, now: now) + ["set found to (every track of lib whose \(condition(track)))"]
            if case let .playlistEntry(_, playlistID) = track {
                // A playlist may list the same song twice; either copy is the song.
                lines += [
                    "if (count of found) is 0 then",
                    "set sourcePls to (every user playlist whose persistent ID is \(quoted(playlistID)))",
                    "if (count of sourcePls) is greater than 0 then",
                    "set inPlaylist to (every track of (item 1 of sourcePls) whose \(condition(track)))",
                    "if (count of inPlaylist) is greater than 0 then set found to {item 1 of inPlaylist}",
                    "end if",
                    "end if",
                ]
            }
            lines += [
                "if (count of found) is 0 then error \"not found\" number \(notFoundError)",
                "if (count of found) is greater than 1 then error \"ambiguous\" number \(ambiguousSongError)",
                "set end of pickedSongs to item 1 of found",
            ]
        }
        return lines
    }

    static func renamePlaylist(_ playlist: MusicAppPlaylistMatch, to name: String) -> String {
        (["tell application \"Music\""] + findPlaylist(playlist) + ["set name of pl to \(quoted(name))", "end tell"])
            .joined(separator: "\n")
    }

    static func deletePlaylist(_ playlist: MusicAppPlaylistMatch) -> String {
        (["tell application \"Music\""] + findPlaylist(playlist) + ["delete pl", "end tell"])
            .joined(separator: "\n")
    }

    /// Sets `pl` to the one user playlist that matches; smart and Apple-made playlists can't be edited.
    private static func findPlaylist(_ playlist: MusicAppPlaylistMatch) -> [String] {
        let filter: String
        switch playlist {
        case let .persistentID(id):
            filter = "persistent ID is \(quoted(id))"
        case let .name(name):
            filter = "name is \(quoted(name))"
        }
        return [
            "set pls to (every user playlist whose \(filter))",
            "if (count of pls) is 0 then error \"not found\" number \(notFoundError)",
            "if (count of pls) is greater than 1 then error \"ambiguous\" number \(ambiguousError)",
            "set pl to item 1 of pls",
            "if smart of pl then error \"smart playlist\" number \(notEditableError)",
        ]
    }

    /// The script's own clock, read once outside the `tell`, so `current date` never goes to Music.
    private static let scriptNowLine = "set scriptNow to (current date)"

    /// Sets `cutoff` for a match limited to tracks added since a save: relative to this Mac's
    /// clock, so no date has to be parsed in AppleScript.
    private static func cutoffLines(_ track: MusicAppTrackMatch, now: Date) -> [String] {
        guard case let .metadata(_, _, _, addedSince?) = track else { return [] }
        let seconds = max(0, Int(now.timeIntervalSince(addedSince).rounded(.up)) + addedSinceMarginSeconds)
        return ["set cutoff to (scriptNow - \(seconds))"]
    }

    /// A `whose` clause (`of` empty) or a test on one track variable.
    private static func condition(_ track: MusicAppTrackMatch, of variable: String? = nil) -> String {
        let prefix = variable.map { " of \($0)" } ?? ""
        switch track {
        case let .persistentID(id), let .playlistEntry(id, _):
            return "persistent ID\(prefix) is \(quoted(id))"
        case let .metadata(name, artist, album, addedSince):
            var parts = ["name\(prefix) is \(quoted(name))", "artist\(prefix) is \(quoted(artist))"]
            if let album, !album.isEmpty {
                parts.append("album\(prefix) is \(quoted(album))")
            }
            if addedSince != nil {
                parts.append("date added\(prefix) is greater than cutoff")
            }
            return parts.joined(separator: " and ")
        }
    }

    /// An AppleScript string literal; quotes and backslashes are escaped, so a title can't end
    /// the string early.
    static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// The editor's outcome for an AppleScript or Apple Event error number.
    static func editError(forScriptErrorNumber number: Int) -> AppleMusicLibraryEditError {
        switch number {
        case notFoundError: .notInMusicYet
        case ambiguousError: .ambiguousPlaylist
        case ambiguousSongError: .ambiguousSong
        case notEditableError: .notEditable
        // errAEEventNotPermitted, errAEEventWouldRequireUserConsent
        case -1743, -1744: .musicControlDenied
        // procNotFound, connectionInvalid, errAETimeout
        case -600, -609, -1712: .musicUnavailable
        default: .requestFailed
        }
    }
}
