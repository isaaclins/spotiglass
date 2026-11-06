import AppKit
import Foundation

/// How the Music app finds a track.
enum MusicAppTrackMatch: Equatable, Sendable {
    /// Music's own persistent ID, 16 hex digits.
    case persistentID(String)
    /// Title, artist and album, for a song added through Apple Music moments ago that this Mac
    /// does not know the persistent ID of yet.
    case metadata(name: String, artist: String, album: String?)
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
}

/// Runs one AppleScript against the Music app. Separate from the script text so tests check
/// the scripts without the Music app.
protocol MusicAppScriptRunning: Sendable {
    func run(_ source: String) async throws
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
}

/// The AppleScript sources. Script errors 9001 to 9003 carry the outcomes the editor reports.
enum MusicAppScripts {
    static let notFoundError = 9001
    static let ambiguousError = 9002
    static let notEditableError = 9003

    static func removeFromLibrary(_ tracks: [MusicAppTrackMatch]) -> String {
        var lines = ["tell application \"Music\"", "set lib to library playlist 1", "set targets to {}"]
        for track in tracks {
            lines += [
                "set found to (every track of lib whose \(condition(track)))",
                "if (count of found) is 0 then error \"not found\" number \(notFoundError)",
                "if (count of found) is greater than 1 then error \"ambiguous\" number \(ambiguousError)",
                "set end of targets to item 1 of found",
            ]
        }
        lines += ["repeat with target in targets", "delete target", "end repeat", "end tell"]
        return lines.joined(separator: "\n")
    }

    /// Deletes from the last position to the first, so earlier positions stay valid. When the
    /// track at a position is no longer the expected one (the playlist changed elsewhere), the
    /// first occurrence of the track is removed instead.
    static func removeFromPlaylist(_ playlist: MusicAppPlaylistMatch, removals: [MusicAppPlaylistRemoval]) -> String {
        let entries = removals
            .flatMap { removal in removal.positions.map { (position: $0, track: removal.track) } }
            .sorted { $0.position > $1.position }
        var lines = ["tell application \"Music\""] + findPlaylist(playlist)
        for entry in entries {
            let index = entry.position + 1
            lines += [
                "set done to false",
                "if \(index) is less than or equal to (count of tracks of pl) then",
                "set t to track \(index) of pl",
                "if \(condition(entry.track, of: "t")) then",
                "delete t",
                "set done to true",
                "end if",
                "end if",
                "if not done then",
                "set found to (every track of pl whose \(condition(entry.track)))",
                "if (count of found) is 0 then error \"not found\" number \(notFoundError)",
                "delete item 1 of found",
                "end if",
            ]
        }
        lines.append("end tell")
        return lines.joined(separator: "\n")
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

    /// A `whose` clause (`of` empty) or a test on one track variable.
    private static func condition(_ track: MusicAppTrackMatch, of variable: String? = nil) -> String {
        let prefix = variable.map { " of \($0)" } ?? ""
        switch track {
        case let .persistentID(id):
            return "persistent ID\(prefix) is \(quoted(id))"
        case let .metadata(name, artist, album):
            var parts = ["name\(prefix) is \(quoted(name))", "artist\(prefix) is \(quoted(artist))"]
            if let album, !album.isEmpty {
                parts.append("album\(prefix) is \(quoted(album))")
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
        case notEditableError: .notEditable
        // errAEEventNotPermitted, errAEEventWouldRequireUserConsent
        case -1743, -1744: .musicControlDenied
        // procNotFound, connectionInvalid, errAETimeout
        case -600, -609, -1712: .musicUnavailable
        default: .requestFailed
        }
    }
}

/// Sends scripts to the Music app. It starts Music hidden when it isn't running, asks for the
/// Automation permission (macOS shows its prompt the first time, and again on the next edit
/// while it is unanswered), then runs the script.
struct AppleEventMusicAppScriptRunner: MusicAppScriptRunning {
    static let musicBundleIdentifier = "com.apple.Music"
    static let launchTimeout: Duration = .seconds(15)

    func run(_ source: String) async throws {
        try await Self.ensureMusicIsRunning()
        try await Self.ensurePermission()
        try await MainActor.run {
            var errorInfo: NSDictionary?
            guard let script = NSAppleScript(source: source) else {
                throw AppleMusicLibraryEditError.requestFailed
            }
            _ = script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                let number = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
                SpotiglassLog.error(.api, "Music script failed (\(number)): \(errorInfo[NSAppleScript.errorMessage] ?? "")")
                throw MusicAppScripts.editError(forScriptErrorNumber: number)
            }
        }
    }

    private static func isMusicRunning() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: musicBundleIdentifier)
            .contains { $0.isFinishedLaunching }
    }

    private static func ensureMusicIsRunning() async throws {
        if isMusicRunning() { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: musicBundleIdentifier) else {
            throw AppleMusicLibraryEditError.musicUnavailable
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } catch {
            throw AppleMusicLibraryEditError.musicUnavailable
        }
        let deadline = ContinuousClock.now + launchTimeout
        while !isMusicRunning() {
            guard ContinuousClock.now < deadline else { throw AppleMusicLibraryEditError.musicUnavailable }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    /// `AEDeterminePermissionToAutomateTarget` blocks until the user answers the prompt, so it
    /// runs off the main thread.
    private static func ensurePermission() async throws {
        let status = await Task.detached(priority: .userInitiated) { () -> OSStatus in
            let target = NSAppleEventDescriptor(bundleIdentifier: musicBundleIdentifier)
            guard let address = target.aeDesc else { return OSStatus(procNotFound) }
            return AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, true)
        }.value
        guard status == noErr else {
            throw MusicAppScripts.editError(forScriptErrorNumber: Int(status))
        }
    }
}
