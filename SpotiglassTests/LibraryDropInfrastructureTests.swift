import SwiftUI
import XCTest
@testable import Spotiglass

final class LibraryDropInfrastructureTests: XCTestCase {
    func testDropInsertionTrackingHelpers() {
        var location: CGPoint?
        LibraryPinnedItemDropDelegate.trackInsertion(at: CGPoint(x: 3, y: 4)) { location = $0 }
        XCTAssertEqual(location, CGPoint(x: 3, y: 4))
        var cleared = false
        LibraryPinnedItemDropDelegate.clearInsertion { cleared = true }
        XCTAssertTrue(cleared)
        XCTAssertEqual(LibraryPinnedItemDropDelegate.dropProposal.operation, .copy)
    }

    func testAcceptsDropCombinesProviderPresence() {
        XCTAssertTrue(
            LibraryPinnedItemDropDelegate.acceptsDrop(
                hasPinned: true,
                hasLibraryRow: false,
                hasPlainText: false,
                hasText: false
            )
        )
        XCTAssertTrue(
            LibraryPinnedItemDropDelegate.acceptsDrop(
                hasPinned: false,
                hasLibraryRow: true,
                hasPlainText: false,
                hasText: false
            )
        )
        XCTAssertTrue(
            LibraryPinnedItemDropDelegate.acceptsDrop(
                hasPinned: false,
                hasLibraryRow: false,
                hasPlainText: true,
                hasText: false
            )
        )
        XCTAssertFalse(
            LibraryPinnedItemDropDelegate.acceptsDrop(
                hasPinned: false,
                hasLibraryRow: false,
                hasPlainText: false,
                hasText: false
            )
        )
    }

    func testLibraryRowFramePreferenceKeyMergesFrames() {
        var value: [String: CGRect] = ["a": CGRect(x: 0, y: 0, width: 1, height: 1)]
        LibraryRowFramePreferenceKey.reduce(value: &value) {
            ["b": CGRect(x: 2, y: 2, width: 3, height: 3)]
        }
        XCTAssertEqual(value.count, 2)
        XCTAssertEqual(value["b"]?.width, 3)
    }

    func testLibrarySidebarRowTransferEncodes() throws {
        let transfer = LibrarySidebarRowTransfer(rowToken: LibrarySidebarOrder.homeToken)
        let data = try JSONEncoder().encode(transfer)
        let decoded = try JSONDecoder().decode(LibrarySidebarRowTransfer.self, from: data)
        XCTAssertEqual(decoded, transfer)
        let provider = transfer.itemProvider()
        XCTAssertFalse(provider.registeredTypeIdentifiers.isEmpty)
    }

    @MainActor
    func testDecodeAndHandlePinnedPayload() throws {
        let item = PinnedItem.playlist(PlaylistBrowsingTestFixtures.playlist(id: "p", name: "P"))
        let transfer = PinnedItemTransfer(item: item, originScopeID: PinnedItemTransfer.pinnedSidebarScopeID)
        let data = try JSONEncoder().encode(transfer)
        XCTAssertEqual(LibraryPinnedItemDropDelegate.decodePinnedTransfer(from: data), transfer)

        var performed = false
        LibraryPinnedItemDropDelegate.handlePinnedPayload(
            data: data,
            location: .zero,
            performPinnedDrop: { decoded, _ in
                performed = (decoded == transfer)
                return true
            },
            clearDragPreview: { XCTFail("should not clear on success") }
        )
        XCTAssertTrue(performed)

        var cleared = false
        LibraryPinnedItemDropDelegate.handlePinnedPayload(
            data: Data(),
            location: .zero,
            performPinnedDrop: { _, _ in true },
            clearDragPreview: { cleared = true }
        )
        XCTAssertTrue(cleared)
    }

    @MainActor
    func testDecodeAndHandleLibraryRowPayload() throws {
        let transfer = LibrarySidebarRowTransfer(rowToken: LibrarySidebarOrder.homeToken)
        let data = try JSONEncoder().encode(transfer)
        XCTAssertEqual(LibraryPinnedItemDropDelegate.decodeLibraryRowTransfer(from: data), transfer)

        var performed = false
        LibraryPinnedItemDropDelegate.handleLibraryRowPayload(
            data: data,
            location: CGPoint(x: 1, y: 2),
            performLibraryRowDrop: { decoded, point in
                performed = decoded == transfer && point == CGPoint(x: 1, y: 2)
                return false
            },
            clearDragPreview: { }
        )
        XCTAssertTrue(performed)
    }

    @MainActor
    func testHandleTextPayloadPinnedAndLibrary() throws {
        let pinned = PinnedItemTransfer(
            item: PinnedItem.playlist(PlaylistBrowsingTestFixtures.playlist(id: "id", name: "P")),
            originScopeID: PinnedItemTransfer.pinnedSidebarScopeID
        )
        let pinnedData = try JSONEncoder().encode(pinned)
        var pinnedPerformed = false
        LibraryPinnedItemDropDelegate.handleTextPayload(
            data: pinnedData,
            location: .zero,
            performPinnedDrop: { transfer, _ in
                pinnedPerformed = transfer == pinned
                return true
            },
            performLibraryRowDrop: { _, _ in false },
            clearDragPreview: { XCTFail("unexpected clear") }
        )
        XCTAssertTrue(pinnedPerformed)

        let row = LibrarySidebarRowTransfer(rowToken: LibrarySidebarOrder.homeToken)
        let rowData = try JSONEncoder().encode(row)
        var rowPerformed = false
        LibraryPinnedItemDropDelegate.handleTextPayload(
            data: rowData,
            location: .zero,
            performPinnedDrop: { _, _ in false },
            performLibraryRowDrop: { transfer, _ in
                rowPerformed = transfer == row
                return true
            },
            clearDragPreview: { XCTFail("unexpected clear") }
        )
        XCTAssertTrue(rowPerformed)

        var cleared = false
        LibraryPinnedItemDropDelegate.handleTextPayload(
            data: Data([0xFF]),
            location: .zero,
            performPinnedDrop: { _, _ in false },
            performLibraryRowDrop: { _, _ in false },
            clearDragPreview: { cleared = true }
        )
        XCTAssertTrue(cleared)
    }
}
