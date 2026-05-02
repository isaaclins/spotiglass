import AppKit
import Foundation

enum CommandPaletteCommandID {
    static let openPalette = "palette.open"
    static let refreshPlaylists = "playlists.refresh"
    static let refreshTracks = "playlists.refreshTracks"
    static let selectNextPlaylist = "navigation.playlists.next"
    static let selectPreviousPlaylist = "navigation.playlists.previous"
    static let openSettings = "app.openSettings"
    static let signOut = "app.signOut"
    static let connectPlayback = "playback.connect"
    static let togglePlayback = "playback.toggle"
    static let nextTrack = "playback.next"
    static let previousTrack = "playback.previous"
    static let disconnectPlayback = "playback.disconnect"
    static let filterByArtist = "search.filterByArtist"
    static let toggleQueue = "queue.toggle"
}

enum CommandPaletteSection: String {
    case commands = "Commands"
    case playlists = "Playlists"
    case tracks = "Tracks"
    case artists = "Artists"
    case albums = "Albums"

    var displayLabel: String {
        switch self {
        case .tracks: "SONGS"
        case .artists: "ARTISTS"
        case .commands: "COMMANDS"
        case .playlists: "PLAYLISTS"
        case .albums: "ALBUMS"
        }
    }
}

enum CommandPaletteScope: Equatable {
    case songs
    case artists
    case commands

    /// Parses raw query input into a scope and stripped query string.
    /// `>` prefix → commands, `@` prefix → artists, otherwise → songs.
    /// The prefix character is removed from the returned query.
    static func parse(_ raw: String) -> (scope: CommandPaletteScope, query: String) {
        if raw.hasPrefix(">") {
            return (.commands, String(raw.dropFirst()))
        }
        if raw.hasPrefix("@") {
            return (.artists, String(raw.dropFirst()))
        }
        return (.songs, raw)
    }
}

enum CommandPaletteContext: String, Codable {
    case always
    case signedIn = "signed_in"
    case signedOut = "signed_out"
    case paletteOpen = "palette_open"
}

struct CommandPaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let iconSystemName: String
    let section: CommandPaletteSection
    let keywords: [String]
    /// When true, executing this item keeps the palette open instead of dismissing it.
    /// Used for actions like "filter by artist" that re-query the palette in place.
    let keepsPaletteOpen: Bool
    let action: @MainActor () async -> Void

    init(
        id: String,
        title: String,
        subtitle: String?,
        iconSystemName: String,
        section: CommandPaletteSection,
        keywords: [String],
        keepsPaletteOpen: Bool = false,
        action: @escaping @MainActor () async -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.iconSystemName = iconSystemName
        self.section = section
        self.keywords = keywords
        self.keepsPaletteOpen = keepsPaletteOpen
        self.action = action
    }

    func score(for query: String) -> Int {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return 0 }
        let haystack = ([title] + (subtitle.map { [$0] } ?? []) + keywords).map { $0.lowercased() }
        var best = Int.max
        for text in haystack {
            if text == needle { best = min(best, 0) }
            if text.hasPrefix(needle) { best = min(best, 1) }
            if text.contains(needle) { best = min(best, 2) }
            let condensed = text.replacingOccurrences(of: " ", with: "")
            if condensed.contains(needle.replacingOccurrences(of: " ", with: "")) {
                best = min(best, 3)
            }
        }
        return best == Int.max ? 100 : best
    }
}

struct CommandPaletteSearchResults {
    var tracks: [CommandPaletteItem] = []
    var artists: [CommandPaletteItem] = []
    var albums: [CommandPaletteItem] = []
    var playlists: [CommandPaletteItem] = []

    var allItems: [CommandPaletteItem] {
        playlists + tracks + artists + albums
    }
}
