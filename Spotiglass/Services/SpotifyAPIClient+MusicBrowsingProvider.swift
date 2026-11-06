import Foundation

/// Spotify is the first `MusicBrowsingProvider`. The client's Web API methods
/// already match the protocol's requirements, so the conformance only declares it.
/// Keeping it here (next to the client) instead of in `Browsing/` keeps the
/// browsing layer free of Spotify types.
extension SpotifyAPIClient: MusicBrowsingProvider {}
