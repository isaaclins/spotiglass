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
}
