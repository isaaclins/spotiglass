import XCTest
@testable import Spotiglass

final class PlaylistOwnerDisplayTests: XCTestCase {
    func testHidesOwnerWhenOwnerIDMatchesCurrentUser() {
        let line = PlaylistOwnerDisplay.ownerTracksLine(
            ownerName: "Isaac",
            ownerID: "user-123",
            trackCountText: "42 tracks",
            currentUserID: "user-123"
        )
        XCTAssertEqual(line, "42 tracks")
    }

    func testShowsOwnerWhenIDsDifferEvenIfDisplayNamesMatch() {
        let line = PlaylistOwnerDisplay.ownerTracksLine(
            ownerName: "Isaac",
            ownerID: "other-user",
            trackCountText: "10 tracks",
            currentUserID: "user-123"
        )
        XCTAssertTrue(line.contains("Isaac"))
        XCTAssertTrue(line.contains("10 tracks"))
    }

    func testShowsOwnerWhenCurrentUserUnknown() {
        let line = PlaylistOwnerDisplay.ownerTracksLine(
            ownerName: "Spotify",
            ownerID: "spotify",
            trackCountText: "5 tracks",
            currentUserID: nil
        )
        XCTAssertTrue(line.contains("Spotify"))
    }

    func testUnknownCountLeavesOnlyTheOwner() {
        let line = PlaylistOwnerDisplay.ownerTracksLine(
            ownerName: "Apple Music",
            ownerID: "apple-curator",
            trackCountText: "",
            currentUserID: "apple-music-library"
        )
        XCTAssertEqual(line, "Apple Music")
    }

    func testAccessibilityLabelWithoutACountHasNoEmptyPart() {
        for locale in ["en", "de", "es"].map(Locale.init(identifier:)) {
            let own = PlaylistOwnerDisplay.accessibilityLabel(
                title: "Road",
                ownerName: "",
                ownerID: "apple-music-library",
                trackCountText: "",
                currentUserID: "apple-music-library",
                nowPlaying: SpotiglassL10n.string("browser.playlistRow.nowPlaying", locale: locale),
                pinned: "",
                locale: locale
            )
            XCTAssertEqual(own, "Road" + SpotiglassL10n.string("browser.playlistRow.nowPlaying", locale: locale))
            let other = PlaylistOwnerDisplay.accessibilityLabel(
                title: "Chill",
                ownerName: "Apple Music",
                ownerID: "curator",
                trackCountText: "",
                currentUserID: "apple-music-library",
                nowPlaying: "",
                pinned: "",
                locale: locale
            )
            XCTAssertFalse(other.hasSuffix(", "), other)
            XCTAssertFalse(other.contains("\u{1}"))
            XCTAssertTrue(other.hasPrefix("Chill, "))
        }
    }

    /// Spotify still names a missing count; only Apple Music rows, whose count loads a moment
    /// after the sidebar, stay quiet.
    func testOnlyAppleMusicRowsHideAnUnknownCount() {
        func row(snapshotID: String) -> PlaylistRowViewModel {
            PlaylistRowViewModel(MusicPlaylistSummary(
                id: "p", name: "P", ownerID: "o", ownerName: "O", imageURL: nil, trackCount: nil, snapshotID: snapshotID
            ))
        }
        XCTAssertEqual(row(snapshotID: AppleMusicItemMapping.playlistSnapshotID).localizedTrackCountText(), "")
        XCTAssertEqual(
            row(snapshotID: "spotify-snapshot").localizedTrackCountText(),
            SpotiglassL10n.string("browser.trackCountUnavailable")
        )
    }
}
