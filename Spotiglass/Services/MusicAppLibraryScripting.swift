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
    /// The script's result as text, when it returns one. A change Music did not answer in time
    /// throws `MusicAppLateChange`.
    @discardableResult
    func run(_ source: String) async throws -> String?
    /// Runs a script that brings an edit to its end after `MusicAppLateChange`. Music answers one
    /// event at a time, so this script's first event waits until the late change is done; a
    /// Music that still doesn't answer ends in `musicStillBusy`.
    @discardableResult
    func settle(_ source: String) async throws -> String?
}

/// A change in an edit script did not answer in time. AppleScript only stops waiting, so Music
/// may still carry it out. `progress` is what the script had done so far (see each script).
struct MusicAppLateChange: Error, Equatable {
    let progress: String
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
        try await run(MusicAppScripts.removeFromLibrary(tracks)) { _ in
            .finish(MusicAppScripts.finishRemovingFromLibrary(tracks))
        }
    }

    func removeFromPlaylist(_ playlist: MusicAppPlaylistMatch, removals: [MusicAppPlaylistRemoval]) async throws {
        guard removals.contains(where: { !$0.positions.isEmpty }) else { return }
        try await run(MusicAppScripts.removeFromPlaylist(playlist, removals: removals)) { progress in
            .finish(MusicAppScripts.finishRemovingFromPlaylist(playlist, entryIDs: MusicAppScripts.list(progress)))
        }
    }

    func renamePlaylist(_ playlist: MusicAppPlaylistMatch, to name: String) async throws {
        try await run(MusicAppScripts.renamePlaylist(playlist, to: name)) { _ in
            .finish(MusicAppScripts.finishRenaming(playlist, to: name))
        }
    }

    func deletePlaylist(_ playlist: MusicAppPlaylistMatch) async throws {
        try await run(MusicAppScripts.deletePlaylist(playlist)) { _ in
            .finish(MusicAppScripts.finishDeleting(playlist))
        }
    }

    func addToPlaylist(_ playlist: MusicAppPlaylistMatch, tracks: [MusicAppTrackMatch]) async throws {
        guard !tracks.isEmpty else { return }
        try await run(MusicAppScripts.addToPlaylist(playlist, tracks: tracks)) { progress in
            .takeBack(MusicAppScripts.takeBackAdd(playlist, progress: progress))
        }
    }

    func createPlaylist(name: String, tracks: [MusicAppTrackMatch]) async throws -> String {
        let result = try await run(MusicAppScripts.createPlaylist(name: name, tracks: tracks)) { progress in
            .takeBack(MusicAppScripts.takeBackCreate(name: name, progress: progress))
        }
        guard let id = result?.trimmingCharacters(in: .whitespacesAndNewlines), UInt64(id, radix: 16) != nil else {
            throw AppleMusicLibraryEditError.requestFailed
        }
        return id
    }

    /// How an edit ends when one of its changes answered late (#411).
    enum LateChangeEnd {
        /// Carry the edit out to the end: removals, renames and deletes can be redone safely,
        /// so the edit succeeds and the screen shows it.
        case finish(String)
        /// Take back what the edit added, so nothing changed and the error is true.
        case takeBack(String)
    }

    /// Runs an edit script. When one of its changes timed out, Music may still carry it out after
    /// the error, so the edit waits until Music answers again and then ends in a state it can
    /// report truthfully: finished, or taken back.
    @discardableResult
    private func run(_ source: String, afterLateChange end: (String) -> LateChangeEnd) async throws -> String? {
        do {
            return try await runner.run(source)
        } catch let late as MusicAppLateChange {
            switch end(late.progress) {
            case let .finish(script):
                try await settle(script)
                return nil
            case let .takeBack(script):
                try await settle(script)
                throw AppleMusicLibraryEditError.musicUnavailable
            }
        }
    }

    /// Runs a settle script. Once a change answered late, Music may have carried it out, so a
    /// settle that fails says the change may still go through; only two playlists or songs that
    /// match alike are a state worth naming as it is.
    private func settle(_ script: String) async throws {
        do {
            try await runner.settle(script)
        } catch let error as AppleMusicLibraryEditError where error == .ambiguousPlaylist || error == .ambiguousSong {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AppleMusicLibraryEditError.musicStillBusy
        }
    }
}

/// The AppleScript sources. Script errors 9001 to 9006 carry the outcomes the editor reports.
enum MusicAppScripts {
    static let notFoundError = 9001
    static let ambiguousError = 9002
    static let notEditableError = 9003
    static let ambiguousSongError = 9004
    /// Music still didn't answer while an edit waited for a late change (`musicStillBusy`).
    static let stillBusyError = 9005
    /// A change timed out; its message is the script's progress (`MusicAppLateChange`).
    static let lateChangeError = 9006
    /// AppleScript's errAETimeout: Music didn't answer one event in time.
    static let eventTimeoutError = -1712
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
        lines += changes(["repeat with target in targets", "delete target", "end repeat"], progress: "\"\"")
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }

    /// After a late change in `removeFromLibrary`: removes what is still there. The first run
    /// found every song, so one that is gone now is one the late delete took.
    static func finishRemovingFromLibrary(_ tracks: [MusicAppTrackMatch], now: Date = Date()) -> String {
        var lines = [scriptNowLine, "tell application \"Music\"", "set lib to library playlist 1"]
        for track in tracks {
            lines += cutoffLines(track, now: now) + [
                "set found to (every track of lib whose \(condition(track)))",
                "if (count of found) is greater than 1 then error \"ambiguous\" number \(ambiguousSongError)",
                "if (count of found) is 1 then delete (item 1 of found)",
            ]
        }
        lines.append("end tell")
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
        lines += changes(
            ["repeat with targetID in targetIDs", "delete (every track of pl whose id is (contents of targetID))", "end repeat"],
            progress: "(targetIDs as text)"
        )
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }

    /// After a late change in `removeFromPlaylist`: deletes the entries it picked that are still
    /// there. `entryIDs` are the entries' IDs from the progress; deleting by ID twice is harmless.
    static func finishRemovingFromPlaylist(_ playlist: MusicAppPlaylistMatch, entryIDs: [String]) -> String {
        var lines = ["tell application \"Music\""] + findPlaylist(playlist)
        for id in entryIDs.compactMap({ Int($0) }) {
            lines.append("delete (every track of pl whose id is \(id))")
        }
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }

    /// Finds every track first, then adds them in order, so a song Music can't find stops the
    /// edit before anything is added. When an add fails partway, the songs this script already
    /// appended are taken out of the playlist again, so the edit is all or nothing. Only entries
    /// past the playlist's old end whose persistent ID this script added go, once per add that
    /// succeeded: a song another device appended meanwhile stays (a failed add records nothing),
    /// and nothing leaves the library.
    static func addToPlaylist(_ playlist: MusicAppPlaylistMatch, tracks: [MusicAppTrackMatch], now: Date = Date()) -> String {
        var lines = [scriptNowLine, "tell application \"Music\""] + findPlaylist(playlist)
        lines += findTracks(tracks, now: now)
        lines += [
            "set countBefore to (count of tracks of pl)",
            "set addedIDs to {}",
            "set pendingID to \"\"",
            "try",
            "repeat with songItem in pickedSongs",
            "set songID to (persistent ID of (contents of songItem))",
            "set pendingID to songID",
            "duplicate (contents of songItem) to pl",
            "set end of addedIDs to songID",
            "set pendingID to \"\"",
            "end repeat",
            "on error errorMessage number errorNumber",
        ]
        // Music may still be adding the song that timed out; a rollback now would miss it.
        lines += lateChange(progress: "(countBefore as text) & \"|\" & (addedIDs as text) & \"|\" & pendingID")
        // The rollback itself can time out halfway; the edit then takes back what is left.
        lines += cleanup(rollbackLines, progress: "(countBefore as text) & \"|\" & (addedIDs as text) & \"|\"") + [
            "error errorMessage number errorNumber",
            "end try",
            "end tell",
        ]
        return lines.joined(separator: "\n")
    }

    /// Takes the entries this script appended out of the playlist again: only entries past its
    /// old end whose persistent ID is in `addedIDs`, once per entry there.
    private static let rollbackLines = [
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
    ]

    /// After a late change in `addToPlaylist`: takes back what it added, the late song included
    /// once Music has added it. `progress` is "countBefore|addedIDs|pendingID".
    static func takeBackAdd(_ playlist: MusicAppPlaylistMatch, progress: String) -> String {
        let parts = progress.components(separatedBy: "|")
        let countBefore = parts.first.flatMap { Int($0) } ?? 0
        let ids = parts.dropFirst().flatMap(list)
        var lines = ["tell application \"Music\""] + findPlaylist(playlist)
        lines += [
            "set countBefore to \(countBefore)",
            "set addedIDs to {\(ids.map(quoted).joined(separator: ", "))}",
        ] + rollbackLines
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }

    /// Finds every track before the playlist exists, and deletes the new playlist again when a
    /// track can't be added, so a failed edit leaves no empty playlist behind (#395). Returns the
    /// new playlist's persistent ID.
    static func createPlaylist(name: String, tracks: [MusicAppTrackMatch], now: Date = Date()) -> String {
        var lines = [scriptNowLine, "tell application \"Music\""] + findTracks(tracks, now: now)
        lines += [
            "set namesakesBefore to (persistent ID of every user playlist whose name is \(quoted(name)))",
            "set newID to \"\"",
            "try",
            "set pl to make new user playlist with properties {name:\(quoted(name))}",
            "set newID to (persistent ID of pl)",
            "repeat with songItem in pickedSongs",
            "duplicate (contents of songItem) to pl",
            "end repeat",
            "on error errorMessage number errorNumber",
        ]
        // Music may still be making the playlist or adding to it; a delete now could miss it.
        lines += lateChange(progress: "newID & \"|\" & (namesakesBefore as text)")
        lines += cleanup(["if newID is not \"\" then delete pl"], progress: "newID & \"|\" & (namesakesBefore as text)") + [
            "error errorMessage number errorNumber",
            "end try",
            "return newID",
            "end tell",
        ]
        return lines.joined(separator: "\n")
    }

    /// After a late change in `createPlaylist`: deletes the new playlist, so a failed create
    /// leaves none behind. `progress` is "newID|namesakesBefore": without the new ID (the make
    /// itself answered late), the new one is the playlist with the name that wasn't there before.
    /// Two such playlists (one made on another device meanwhile) can't be told apart: both stay.
    static func takeBackCreate(name: String, progress: String) -> String {
        let parts = progress.components(separatedBy: "|")
        let newID = parts.first ?? ""
        let before = parts.dropFirst().flatMap(list)
        var lines = ["tell application \"Music\""]
        if UInt64(newID, radix: 16) != nil {
            lines.append("delete (every user playlist whose persistent ID is \(quoted(newID)))")
        } else {
            lines += [
                "set namesakesBefore to {\(before.map(quoted).joined(separator: ", "))}",
                "set made to {}",
                "repeat with candidate in (every user playlist whose name is \(quoted(name)))",
                "if namesakesBefore does not contain (persistent ID of candidate) then set end of made to (contents of candidate)",
                "end repeat",
                "if (count of made) is greater than 1 then error \"ambiguous\" number \(ambiguousError)",
                "if (count of made) is 1 then delete (item 1 of made)",
            ]
        }
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }

    /// The change part of an edit script: a change that times out stops the script with
    /// `lateChangeError` and `progress` (an AppleScript expression, lists joined by commas), so
    /// the edit can wait for Music and end truthfully. A lookup that times out changed nothing
    /// and stays errAETimeout.
    static func changes(_ lines: [String], progress: String) -> [String] {
        ["try"] + lines + ["on error errorMessage number errorNumber"] + lateChange(progress: progress) + [
            "error errorMessage number errorNumber",
            "end try",
        ]
    }

    /// The cleanup inside an edit's `on error`: a cleanup that times out may stop halfway while
    /// Music still carries out the step that timed out, so it becomes `lateChangeError` with
    /// `progress` too, and the edit's take-back finishes the cleanup once Music answers.
    static func cleanup(_ lines: [String], progress: String) -> [String] {
        ["try"] + lines + ["on error cleanupMessage number cleanupNumber"]
            + lateChange(progress: progress, number: "cleanupNumber")
            + ["error cleanupMessage number cleanupNumber", "end try"]
    }

    /// Inside an `on error`: a timeout becomes `lateChangeError` with `progress`.
    private static func lateChange(progress: String, number: String = "errorNumber") -> [String] {
        [
            "if \(number) is \(eventTimeoutError) then",
            "set AppleScript's text item delimiters to \",\"",
            "error (\(progress)) number \(lateChangeError)",
            "end if",
        ]
    }

    /// The items of a progress list, joined by commas.
    static func list(_ text: String) -> [String] {
        text.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Wraps a script that ends an edit after a late change. It may wait `seconds` for Music;
    /// a Music that still doesn't answer ends in `stillBusyError`.
    static func settling(_ source: String, seconds: Int) -> String {
        [
            "with timeout of \(seconds) seconds",
            "try",
            source,
            "on error errorMessage number errorNumber",
            "if errorNumber is \(eventTimeoutError) then error \"Music is still busy\" number \(stillBusyError)",
            "error errorMessage number errorNumber",
            "end try",
            "end timeout",
        ].joined(separator: "\n")
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
        (["tell application \"Music\""] + findPlaylist(playlist)
            + changes(["set name of pl to \(quoted(name))"], progress: "\"\"") + ["end tell"])
            .joined(separator: "\n")
    }

    /// After a late rename: renames again, which is harmless. A playlist found by its old name is
    /// done once that name is gone and the new one is there.
    static func finishRenaming(_ playlist: MusicAppPlaylistMatch, to name: String) -> String {
        var lines = ["tell application \"Music\""]
        if case let .name(oldName) = playlist {
            lines += [
                "if (count of (every user playlist whose name is \(quoted(oldName)))) is 0 and (count of (every user playlist whose name is \(quoted(name)))) is greater than 0 then return",
            ]
        }
        lines += findPlaylist(playlist) + ["set name of pl to \(quoted(name))", "end tell"]
        return lines.joined(separator: "\n")
    }

    static func deletePlaylist(_ playlist: MusicAppPlaylistMatch) -> String {
        (["tell application \"Music\""] + findPlaylist(playlist) + changes(["delete pl"], progress: "\"\"") + ["end tell"])
            .joined(separator: "\n")
    }

    /// After a late delete: the first run found the playlist, so one that is gone now is one the
    /// late delete took; one still there is deleted now.
    static func finishDeleting(_ playlist: MusicAppPlaylistMatch) -> String {
        (["tell application \"Music\"", "if (count of (every user playlist whose \(playlistFilter(playlist)))) is 0 then return"]
            + findPlaylist(playlist) + ["delete pl", "end tell"])
            .joined(separator: "\n")
    }

    /// Sets `pl` to the one user playlist that matches; smart and Apple-made playlists can't be edited.
    private static func findPlaylist(_ playlist: MusicAppPlaylistMatch) -> [String] {
        [
            "set pls to (every user playlist whose \(playlistFilter(playlist)))",
            "if (count of pls) is 0 then error \"not found\" number \(notFoundError)",
            "if (count of pls) is greater than 1 then error \"ambiguous\" number \(ambiguousError)",
            "set pl to item 1 of pls",
            "if smart of pl then error \"smart playlist\" number \(notEditableError)",
        ]
    }

    private static func playlistFilter(_ playlist: MusicAppPlaylistMatch) -> String {
        switch playlist {
        case let .persistentID(id): "persistent ID is \(quoted(id))"
        case let .name(name): "name is \(quoted(name))"
        }
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
        case stillBusyError: .musicStillBusy
        // errAEEventNotPermitted, errAEEventWouldRequireUserConsent
        case -1743, -1744: .musicControlDenied
        // procNotFound, connectionInvalid, errAETimeout
        case -600, -609, -1712: .musicUnavailable
        default: .requestFailed
        }
    }
}
