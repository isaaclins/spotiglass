import XCTest
@testable import Spotiglass

final class PinnedItemsCacheTests: XCTestCase {
    func testInMemoryRoundTripPerUser() throws {
        let cache = InMemoryPinnedItemsCache()
        let pin = PinnedItem.playlist(
            SpotifyPlaylistSummary(
                id: "p1", name: "Mix", ownerName: "Me",
                imageURL: nil, trackCount: 1, snapshotID: "s"
            )
        )
        try cache.savePinnedItems([pin], userID: "user-a")
        XCTAssertTrue(try cache.loadPinnedItems(userID: "user-a").contains(where: { $0.id == pin.id }))
        XCTAssertTrue(try cache.loadPinnedItems(userID: "user-b").isEmpty)
    }
}
