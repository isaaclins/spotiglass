import CoreGraphics
import XCTest
@testable import Spotiglass

final class LibraryDropInfrastructureTests: XCTestCase {
    func testLibraryRowFramePreferenceKeyMergesFrames() {
        var value: [String: CGRect] = ["a": CGRect(x: 0, y: 0, width: 1, height: 1)]
        LibraryRowFramePreferenceKey.reduce(value: &value) {
            ["b": CGRect(x: 2, y: 2, width: 3, height: 3)]
        }
        XCTAssertEqual(value.count, 2)
        XCTAssertEqual(value["b"]?.width, 3)
    }

    func testLibrarySidebarRowTransferRoundTrip() throws {
        let transfer = LibrarySidebarRowTransfer(rowToken: LibrarySidebarOrder.homeToken)
        let data = try JSONEncoder().encode(transfer)
        let decoded = try JSONDecoder().decode(LibrarySidebarRowTransfer.self, from: data)
        XCTAssertEqual(decoded, transfer)
    }

    func testLibraryPinnedItemDropDelegateAcceptedTypesAreNonEmpty() {
        XCTAssertFalse(LibraryPinnedItemDropDelegate.acceptedTypeIdentifiers.isEmpty)
    }

    func testAcceptsDropRequiresKnownProviderKinds() {
        XCTAssertTrue(LibraryPinnedItemDropDelegate.acceptsDrop(
            hasPinned: true, hasLibraryRow: false, hasPlainText: false, hasText: false
        ))
        XCTAssertTrue(LibraryPinnedItemDropDelegate.acceptsDrop(
            hasPinned: false, hasLibraryRow: false, hasPlainText: true, hasText: false
        ))
        XCTAssertFalse(LibraryPinnedItemDropDelegate.acceptsDrop(
            hasPinned: false, hasLibraryRow: false, hasPlainText: false, hasText: false
        ))
    }
}
