import Foundation

/// Subtitle lines for playlist rows (sidebar, detail header, command palette).
enum PlaylistOwnerDisplay {
    /// Owner • track count, or track count only when the playlist owner is the signed-in user.
    static func ownerTracksLine(
        ownerName: String,
        ownerID: String,
        trackCountText: String,
        currentUserID: String?
    ) -> String {
        guard let currentUserID, !ownerID.isEmpty, ownerID == currentUserID else {
            return String(
                format: SpotiglassL10n.string("browser.playlistOwnerTracks"),
                ownerName,
                trackCountText
            )
        }
        return trackCountText
    }

    static func palettePlaylistSubtitle(
        ownerName: String,
        ownerID: String,
        currentUserID: String?
    ) -> String {
        guard let currentUserID, !ownerID.isEmpty, ownerID == currentUserID else {
            return String(format: SpotiglassL10n.string("browser.palette.subtitle.playlist"), ownerName)
        }
        return SpotiglassL10n.string("browser.palette.subtitle.playlistOwn")
    }

    static func accessibilityLabel(
        title: String,
        ownerName: String,
        ownerID: String,
        trackCountText: String,
        currentUserID: String?,
        nowPlaying: String,
        pinned: String
    ) -> String {
        if let currentUserID, !ownerID.isEmpty, ownerID == currentUserID {
            return String(
                format: SpotiglassL10n.string("browser.playlistRow.accessibilityOwnPlaylist"),
                title,
                trackCountText,
                nowPlaying,
                pinned
            )
        }
        return String(
            format: SpotiglassL10n.string("browser.playlistRow.accessibility"),
            title,
            ownerName,
            trackCountText,
            nowPlaying,
            pinned
        )
    }
}
