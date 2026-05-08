import AppKit
import XCTest
@testable import Spotiglass

@MainActor
final class CommandPaletteManagerTests: XCTestCase {
    func testManagerOpenPaletteCommandShowsOverlay() {
        let manager = CommandPaletteManager()
        XCTAssertFalse(manager.viewModel.isPresented)
        manager.execute(commandID: CommandPaletteCommandID.openPalette)
        XCTAssertTrue(manager.viewModel.isPresented)
    }

    func testOpenArtistCommandInvokesHandler() async {
        let manager = CommandPaletteManager()
        let expectation = expectation(description: "openArtist")
        var receivedID: String?
        manager.openArtist = { id in
            receivedID = id
            expectation.fulfill()
        }
        manager.execute(commandID: CommandPaletteCommandID.openArtist, args: ["artistID": .string("abc123")])
        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(receivedID, "abc123")
    }

    func testToggleLyricsCommandInvokesHandler() {
        let manager = CommandPaletteManager()
        var toggled = false
        manager.toggleLyrics = { toggled = true }
        manager.execute(commandID: CommandPaletteCommandID.toggleLyrics)
        XCTAssertTrue(toggled)
    }

}
