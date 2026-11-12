import Foundation

/// Spotify's library-edit check: each edit needs OAuth scopes the session may have been granted
/// without (an account authorized before Spotiglass asked for them). A missing scope comes back
/// as ``SpotifyAPIError/insufficientScope(requiredScopes:message:details:)``, so the toast points
/// at Settings ▸ Account ▸ Reconnect.
struct SpotifyLibraryEditPermissions: MusicLibraryEditPermissions {
    let scopes: any SpotifyScopeProviding

    func missingPermission(for operation: PlaylistMutationOperation) async -> Error? {
        let requirement = Self.requirement(for: operation)
        guard !requirement.isEmpty else { return nil }
        let missing = requirement.missingScopes(from: await scopes.grantedScopes())
        guard !missing.isEmpty else { return nil }
        return SpotifyAPIError.insufficientScope(
            requiredScopes: missing,
            message: nil,
            details: "Scope preflight denied a playlist mutation: missing \(missing.joined(separator: ", "))."
        )
    }

    static func requirement(for operation: PlaylistMutationOperation) -> SpotifyScopeRequirement {
        switch operation {
        case .addToPlaylist, .moveBetweenPlaylists, .renamePlaylist:
            SpotifyScopeRequirement(anyOf: SpotifyAuthConfiguration.requiredPlaylistModifyScopes)
        case .addToLikedSongs, .removeFromLikedSongs:
            SpotifyScopeRequirement(allOf: SpotifyAuthConfiguration.requiredSavedTracksModifyScopes)
        case .createPlaylist:
            SpotifyScopeRequirement(allOf: [SpotifyAuthConfiguration.requiredPlaylistModifyScopes[0]])
        case .generic, .removeFromPlaylist, .deletePlaylist, .saveAlbum:
            SpotifyScopeRequirement()
        }
    }
}
