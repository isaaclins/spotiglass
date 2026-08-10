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

    func testExecuteWiresRemainingHandlers() async {
        let manager = CommandPaletteManager()
        manager.isSignedIn = true

        let signOut = expectation(description: "signOut")
        manager.signOut = { signOut.fulfill() }
        manager.execute(commandID: CommandPaletteCommandID.signOut)
        await fulfillment(of: [signOut], timeout: 2)

        let settings = expectation(description: "settings")
        manager.openSettings = { settings.fulfill() }
        manager.execute(commandID: CommandPaletteCommandID.openSettings)
        await fulfillment(of: [settings], timeout: 2)

        manager.connectPlayback = {}
        manager.execute(commandID: CommandPaletteCommandID.connectPlayback)

        let next = expectation(description: "next")
        manager.selectNextPlaylist = { next.fulfill() }
        manager.execute(commandID: CommandPaletteCommandID.selectNextPlaylist)
        await fulfillment(of: [next], timeout: 2)

        let playURI = expectation(description: "playURI")
        manager.playURI = { uri in
            XCTAssertEqual(uri, "spotify:track:1")
            playURI.fulfill()
        }
        manager.execute(commandID: "playback.playURI", args: ["uri": .string("spotify:track:1")])
        await fulfillment(of: [playURI], timeout: 2)

        var filtered: String?
        manager.filterByArtist = { filtered = $0 }
        manager.execute(commandID: CommandPaletteCommandID.filterByArtist, args: ["name": .string("Artist")])
        XCTAssertEqual(filtered, "Artist")

        var queueToggled = false
        manager.toggleQueue = { queueToggled = true }
        manager.execute(commandID: CommandPaletteCommandID.toggleQueue)
        XCTAssertTrue(queueToggled)
    }

    func testBaseItemsRespectsSignIn() {
        let manager = CommandPaletteManager()
        manager.isSignedIn = false
        let signedOutCount = manager.viewModel.staticItemsProvider().count
        manager.isSignedIn = true
        let signedInCount = manager.viewModel.staticItemsProvider().count
        XCTAssertGreaterThanOrEqual(signedInCount, signedOutCount)
    }

}
