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
    /// Menu bar only: flips Spotify shuffle for the active device. Deliberately
    /// absent from ``CommandPaletteCommandCatalog/editable``, so it has no palette
    /// row and no rebindable keystroke, and the Playback menu owns its ⌥⌘S chord.
    /// Menu bar only. Acts on the track table's selection, unlike
    /// ``enqueueSelected`` and ``pinSelected``, which are scoped to the palette
    /// and act on its own highlighted row (#132).
    static let enqueueTrackSelection = "browser.selection.enqueue"
    static let pinTrackSelection = "browser.selection.pin"
    static let toggleShuffle = "playback.shuffle"
    /// Menu bar only, same reasoning as ``toggleShuffle``: cycles off, context, track.
    static let cycleRepeat = "playback.repeat"
    /// Menu bar only: pops the browser's navigation stack. Absent from
    /// ``CommandPaletteCommandCatalog/editable`` so no keymap entry can shadow
    /// the View menu's ⌘[ , which is the standard Mac key equivalent for Back.
    static let navigateBack = "navigation.back"
    /// Menu bar only, like shuffle and repeat: nudges playback position by a
    /// fixed step so seeking has a keyboard path at all.
    static let seekForward = "playback.seekForward"
    static let seekBackward = "playback.seekBackward"
    static let filterByArtist = "search.filterByArtist"
    static let toggleQueue = "queue.toggle"
    static let toggleLyrics = "lyrics.toggle"
    static let openArtist = "navigation.artist.open"
    /// Opens an album result through the browser's existing album-detail path.
    /// This is an internal palette-result action, not an editable keymap command.
    static let openAlbum = "navigation.album.open"
    /// Opens the dedicated full-window catalog Search view. Default ⌘F.
    static let openSearch = "navigation.search.open"
    /// Pin the currently-selected palette result. Default ⌘↩ in `.paletteOpen`.
    static let pinSelected = "palette.pin"
    /// Unpin the currently-selected palette result. No default keystroke.
    static let unpinSelected = "palette.unpin"
    /// Add the currently-selected palette result to the playback queue. Default ⇧↩ in `.paletteOpen`.
    static let enqueueSelected = "palette.enqueue"
    /// Bulk-warm the on-disk track cache for every library playlist + Liked Songs so subsequent opens are instant.
    static let prefetchAllPlaylists = "playlists.prefetchAll"
}

/// Progress reported by the bulk "Load all your songs into Spotiglass" run.
/// Mirrored from `PlaylistBrowserViewModel` onto `CommandPaletteViewModel` so the
/// palette can render an inline header without owning the work itself.
struct PrefetchAllPlaylistsProgress: Equatable {
    enum Phase: Equatable {
        case running
        /// Run reached the end of the work list (any per-item failures are
        /// captured in `failed`).
        case finished
        /// User toggled the command again or signed out; partial counts kept.
        case cancelled
    }

    var phase: Phase
    var total: Int
    var completed: Int
    var skipped: Int
    var failed: Int

    var isTerminal: Bool {
        phase != .running
    }
}

extension PrefetchAllPlaylistsProgress {
    var processedCount: Int {
        completed + skipped + failed
    }

    /// Shared copy for the command palette and the always-visible browser
    /// toolbar indicator. A zero-total running state is the preparing phase.
    var localizedStatusLabel: String {
        switch phase {
        case .running:
            if total == 0 { return SpotiglassL10n.string("palette.prefetch.preparing") }
            return SpotiglassL10n.format(
                "palette.prefetch.loading",
                Int64(processedCount),
                Int64(total)
            )
        case .finished:
            if failed == 0 {
                return SpotiglassL10n.format(
                    "palette.prefetch.loadedAll",
                    Int64(completed + skipped)
                )
            }
            return SpotiglassL10n.format(
                "palette.prefetch.loadedPartial",
                Int64(completed + skipped),
                Int64(total),
                Int64(failed)
            )
        case .cancelled:
            return SpotiglassL10n.format(
                "palette.prefetch.cancelled",
                Int64(processedCount),
                Int64(total)
            )
        }
    }
}

enum CommandPaletteSection: String {
    case commands = "Commands"
    case playlists = "Playlists"
    case thisPlaylist = "This playlist"
    case myPlaylists = "My Playlists"
    case tracks = "Tracks"
    case artists = "Artists"
    case albums = "Albums"
    /// Single-row footer section holding the "Show all results" handoff into the Search view.
    case showAll = "Show all"

    var displayLabel: String {
        switch self {
        case .tracks: SpotiglassL10n.string("palette.section.tracks")
        case .artists: SpotiglassL10n.string("palette.section.artists")
        case .commands: SpotiglassL10n.string("palette.section.commands")
        case .playlists: SpotiglassL10n.string("palette.section.playlists")
        case .thisPlaylist: SpotiglassL10n.string("palette.section.thisPlaylist")
        case .myPlaylists: SpotiglassL10n.string("palette.section.myPlaylists")
        case .albums: SpotiglassL10n.string("palette.section.albums")
        case .showAll: SpotiglassL10n.string("palette.section.showAll")
        }
    }
}

enum CommandPaletteScope: Equatable {
    case songs
    case commands

    /// Parses raw query input into a scope and stripped query string.
    /// `>` prefix → commands; otherwise Spotify search (category comes from `CommandPaletteSearchCategory`).
    /// A leading `@` is legacy artist-only shorthand; the view model strips it and sets category to artists.
    static func parse(_ raw: String) -> (scope: CommandPaletteScope, query: String) {
        if raw.hasPrefix(">") {
            return (.commands, String(raw.dropFirst()))
        }
        return (.songs, raw)
    }
}

/// Spotify search result category shown in the palette footer; filters which sections appear after a query.
enum CommandPaletteSearchCategory: String, Identifiable, Hashable {
    case all
    case tracks
    case artists
    case thisPlaylist
    case myPlaylists

    var id: String { rawValue }

    var segmentLabel: String {
        switch self {
        case .all: SpotiglassL10n.string("palette.searchCategory.all")
        case .tracks: SpotiglassL10n.string("palette.searchCategory.tracks")
        case .artists: SpotiglassL10n.string("palette.searchCategory.artists")
        case .thisPlaylist: SpotiglassL10n.string("palette.searchCategory.here")
        case .myPlaylists: SpotiglassL10n.string("palette.searchCategory.myPlaylists")
        }
    }

    /// Footer segment order. `.all` leads as the smart default (typing immediately searches
    /// everything — loaded songs and the catalog — ranked by relevance); `thisPlaylist` ("Here")
    /// is appended only when a playlist is open in the browser.
    static func footerOrder(includeThisPlaylist: Bool) -> [CommandPaletteSearchCategory] {
        var order: [CommandPaletteSearchCategory] = [.all, .tracks, .artists]
        if includeThisPlaylist {
            order.append(.thisPlaylist)
        }
        order.append(.myPlaylists)
        return order
    }

    /// Next category when cycling forward (Tab) within `ordered`.
    func next(in ordered: [CommandPaletteSearchCategory]) -> CommandPaletteSearchCategory {
        guard let idx = ordered.firstIndex(of: self), !ordered.isEmpty else { return ordered.first ?? .all }
        return ordered[(idx + 1) % ordered.count]
    }

    /// Previous category when cycling backward (Shift+Tab) within `ordered`.
    func previous(in ordered: [CommandPaletteSearchCategory]) -> CommandPaletteSearchCategory {
        guard let idx = ordered.firstIndex(of: self), !ordered.isEmpty else { return ordered.first ?? .all }
        return ordered[(idx + ordered.count - 1) % ordered.count]
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
    /// Spotify artist image URL for palette rows in `.artists`; `nil` uses `iconSystemName` only.
    let artistAvatarURL: URL?
    /// Spotify album cover URL for `.tracks` / `.thisPlaylist` rows; `nil` falls back to `iconSystemName`.
    let trackArtworkURL: URL?
    let section: CommandPaletteSection
    let keywords: [String]
    /// When true, executing this item keeps the palette open instead of dismissing it.
    /// Used for actions like "filter by artist" that re-query the palette in place.
    let keepsPaletteOpen: Bool
    let action: @MainActor () async -> Void
    /// When non-`nil`, ⌘↩ on this item pins it to the sidebar instead of
    /// running ``action``. Set by the palette search builder for any pinnable
    /// kind (track, artist, album, catalog playlist, library playlist).
    let pinAction: (@MainActor () -> Void)?
    /// When non-`nil`, marks the row as already pinned and provides the unpin
    /// closure (used by the future "Unpin from Sidebar" command).
    let unpinAction: (@MainActor () -> Void)?
    /// When non-`nil`, ⇧↩ on this item enqueues it (typically a track URI add)
    /// without dismissing the palette. `nil` for non-track rows so ⇧↩ silently
    /// no-ops on commands, artists, albums, and playlists.
    let queueAction: (@MainActor () async -> Void)?
    /// When `true`, the palette renders an "Explicit" capsule next to the title,
    /// mirroring the badge shown in `TrackListRow`. Only meaningful for track rows.
    let isExplicit: Bool
    /// Dynamic guard for actions whose readiness can change while the palette is open.
    /// A failed guard leaves the palette visible instead of claiming the action ran.
    let canExecute: (@MainActor () -> Bool)?

    init(
        id: String,
        title: String,
        subtitle: String?,
        iconSystemName: String,
        artistAvatarURL: URL? = nil,
        trackArtworkURL: URL? = nil,
        section: CommandPaletteSection,
        keywords: [String],
        keepsPaletteOpen: Bool = false,
        pinAction: (@MainActor () -> Void)? = nil,
        unpinAction: (@MainActor () -> Void)? = nil,
        queueAction: (@MainActor () async -> Void)? = nil,
        isExplicit: Bool = false,
        canExecute: (@MainActor () -> Bool)? = nil,
        action: @escaping @MainActor () async -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.iconSystemName = iconSystemName
        self.artistAvatarURL = artistAvatarURL
        self.trackArtworkURL = trackArtworkURL
        self.section = section
        self.keywords = keywords
        self.keepsPaletteOpen = keepsPaletteOpen
        self.pinAction = pinAction
        self.unpinAction = unpinAction
        self.queueAction = queueAction
        self.isExplicit = isExplicit
        self.canExecute = canExecute
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
    /// Spotify catalog playlist hits from `/v1/search`.
    var catalogPlaylists: [CommandPaletteItem] = []
    /// Tracks in the currently open playlist (or Liked Songs) matching the query; built locally.
    var inPlaylistMatches: [CommandPaletteItem] = []
    /// Current user's library playlists that match the query (filtered in-app).
    var myPlaylists: [CommandPaletteItem] = []

    /// Catalog hits first, then library playlists not already in the catalog list.
    func mergedPlaylistsForAllCategory() -> [CommandPaletteItem] {
        let catalogIDs = Set(catalogPlaylists.compactMap { Self.playlistSpotifyID(fromItemID: $0.id) })
        let libraryExtras = myPlaylists.filter { item in
            guard let sid = Self.playlistSpotifyID(fromItemID: item.id) else { return true }
            return !catalogIDs.contains(sid)
        }
        return catalogPlaylists + libraryExtras
    }

    private static func playlistSpotifyID(fromItemID id: String) -> String? {
        guard id.hasPrefix("playlist-") else { return nil }
        return String(id.dropFirst("playlist-".count))
    }
}

/// Whether the current track selection offers Pin, Unpin, or neither.
///
/// `unavailable` covers both an empty selection and rows that cannot be pinned
/// at all, such as episodes and local files, so the menu item dims instead of
/// pretending it will work (#132).
enum TrackSelectionPinState {
    case unavailable
    case pin
    case unpin
}

/// Whether the current track selection offers adding to or removing from Liked Songs.
enum TrackSelectionLikedState: Equatable {
    case unavailable
    case add
    case remove
}
