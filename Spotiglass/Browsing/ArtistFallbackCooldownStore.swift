import Foundation

/// Artist fallback request budget. Spotify's supported album-track route is requested
/// once per selected release, with a small fixed ceiling to keep artist loads bounded.
struct ArtistAlbumFallbackStrategy {
    static let maxAlbumRequests = 6
}
