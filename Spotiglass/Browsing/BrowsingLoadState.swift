import Foundation

/// Identifies a playlist the user follows but does not own, whose track listing
/// Spotify's Web API now refuses (HTTP 403). Carries just enough to still offer
/// playback and an "open in Spotify" fallback.
struct LockedPlaylistInfo: Equatable {
    let playlistID: String
    let name: String
    var contextURI: String { "spotify:playlist:\(playlistID)" }
    var externalURL: URL? { URL(string: "https://open.spotify.com/playlist/\(playlistID)") }
}

struct BrowsingDisplayError: Equatable, Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let canRetry: Bool
    let diagnosticDetails: String?
    let lockedPlaylist: LockedPlaylistInfo?

    init(
        title: String, message: String, canRetry: Bool, diagnosticDetails: String? = nil,
        lockedPlaylist: LockedPlaylistInfo? = nil
    ) {
        self.title = title
        self.message = message
        self.canRetry = canRetry
        self.diagnosticDetails = diagnosticDetails
        self.lockedPlaylist = lockedPlaylist
    }

    static func == (lhs: BrowsingDisplayError, rhs: BrowsingDisplayError) -> Bool {
        lhs.title == rhs.title
            && lhs.message == rhs.message
            && lhs.canRetry == rhs.canRetry
            && lhs.diagnosticDetails == rhs.diagnosticDetails
            && lhs.lockedPlaylist == rhs.lockedPlaylist
    }
}

enum BrowsingLoadState<Value: Equatable>: Equatable {
    case loading
    case loaded(Value)
    case empty(String)
    case staleCache(Value, BrowsingDisplayError?)
    case refreshing(Value)
    case error(BrowsingDisplayError)

    var currentValue: Value? {
        switch self {
        case .loaded(let value), .staleCache(let value, _), .refreshing(let value):
            value
        case .loading, .empty, .error:
            nil
        }
    }
}
