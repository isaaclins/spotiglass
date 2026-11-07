import Foundation

/// Subtitle lines for playlist rows (sidebar, detail header, command palette).
enum PlaylistOwnerDisplay {
    /// Owner • track count, or track count only when the playlist owner is the signed-in user.
    /// An empty `trackCountText` (count not known) leaves the count and its separator out.
    static func ownerTracksLine(
        ownerName: String,
        ownerID: String,
        trackCountText: String,
        currentUserID: String?,
        locale: Locale = SpotiglassL10n.locale
    ) -> String {
        guard let currentUserID, !ownerID.isEmpty, ownerID == currentUserID else {
            if trackCountText.isEmpty { return ownerName }
            return String(
                format: SpotiglassL10n.string("browser.playlistOwnerTracks", locale: locale),
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
        pinned: String,
        locale: Locale = SpotiglassL10n.locale
    ) -> String {
        // Every format puts ", " before the count; without a count that part goes, in any language.
        let countMarker = "\u{1}"
        let count = trackCountText.isEmpty ? countMarker : trackCountText
        return label(
            title: title,
            ownerName: ownerName,
            ownerID: ownerID,
            trackCountText: count,
            currentUserID: currentUserID,
            nowPlaying: nowPlaying,
            pinned: pinned,
            locale: locale
        ).replacingOccurrences(of: ", " + countMarker, with: "")
            .replacingOccurrences(of: countMarker, with: "")
    }

    private static func label(
        title: String,
        ownerName: String,
        ownerID: String,
        trackCountText: String,
        currentUserID: String?,
        nowPlaying: String,
        pinned: String,
        locale: Locale
    ) -> String {
        if let currentUserID, !ownerID.isEmpty, ownerID == currentUserID {
            return String(
                format: SpotiglassL10n.string("browser.playlistRow.accessibilityOwnPlaylist", locale: locale),
                title,
                trackCountText,
                nowPlaying,
                pinned
            )
        }
        return String(
            format: SpotiglassL10n.string("browser.playlistRow.accessibility", locale: locale),
            title,
            ownerName,
            trackCountText,
            nowPlaying,
            pinned
        )
    }
}
