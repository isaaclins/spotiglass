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

    func testDetachingOneSceneDoesNotResetAnotherPalette() {
        let first = CommandPaletteManager()
        let second = CommandPaletteManager()
        first.isSignedIn = true
        second.isSignedIn = true
        first.viewModel.show()
        second.viewModel.show()
        first.viewModel.query = "first scene"
        second.viewModel.query = "second scene"

        first.detach()

        XCTAssertFalse(first.viewModel.isPresented)
        XCTAssertEqual(first.viewModel.query, "")
        XCTAssertTrue(second.viewModel.isPresented)
        XCTAssertEqual(second.viewModel.query, "second scene")
        XCTAssertTrue(second.isSignedIn)
    }

    func testSignOutCommandDetachesBeforeCallingAuthHandler() {
        let manager = CommandPaletteManager()
        manager.isSignedIn = true
        manager.viewModel.show()
        manager.viewModel.query = "stale query"
        var wasResetBeforeSignOut = false
        manager.signOut = {
            wasResetBeforeSignOut = !manager.viewModel.isPresented
                && manager.viewModel.query.isEmpty
                && !manager.isSignedIn
        }

        manager.execute(commandID: CommandPaletteCommandID.signOut)

        XCTAssertTrue(wasResetBeforeSignOut)
        XCTAssertNil(manager.signOut)
    }

    func testInactiveSceneDoesNotConsumePaletteKeyEvent() {
        let manager = CommandPaletteManager()
        manager.viewModel.show()
        manager.isCurrentScene = { false }
        let escape = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 53
        )!

        XCTAssertFalse(manager.handleKeyEvent(escape))
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

    func testOpenAlbumCommandInvokesHandlerWithMetadata() async {
        let manager = CommandPaletteManager()
        let opened = expectation(description: "openAlbum")
        var received: (id: String, title: String, subtitle: String, artworkURL: URL?)?
        manager.openAlbum = { id, title, subtitle, artworkURL in
            received = (id, title, subtitle, artworkURL)
            opened.fulfill()
        }
        manager.execute(
            commandID: CommandPaletteCommandID.openAlbum,
            args: [
                "albumID": .string("album-1"),
                "title": .string("Night Drive"),
                "subtitle": .string("M83"),
                "artworkURL": .string("https://example.com/album.png"),
            ]
        )
        await fulfillment(of: [opened], timeout: 2)
        XCTAssertEqual(received?.id, "album-1")
        XCTAssertEqual(received?.title, "Night Drive")
        XCTAssertEqual(received?.subtitle, "M83")
        XCTAssertEqual(received?.artworkURL, URL(string: "https://example.com/album.png"))
    }

    func testToggleLyricsCommandInvokesHandler() {
        let manager = CommandPaletteManager()
        manager.setLyricsToggleAvailability(true)
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

        manager.connectPlayback = { }
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

    func testLyricsCommandRequiresCurrentMusicTrack() {
        let manager = CommandPaletteManager()
        manager.isSignedIn = true
        let playback = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander()
        )
        manager.bindPlaybackReadiness(to: playback)
        var dispatchCount = 0
        manager.toggleLyrics = { dispatchCount += 1 }

        XCTAssertFalse(
            manager.viewModel.staticItemsProvider().contains { $0.id == CommandPaletteCommandID.toggleLyrics }
        )
        manager.execute(commandID: CommandPaletteCommandID.toggleLyrics)
        XCTAssertEqual(dispatchCount, 0)

        let episode = PlaybackNowPlaying(
            name: "Episode",
            artists: ["Host"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 100,
            positionMilliseconds: 0,
            uri: "spotify:episode:1"
        )
        playback.setConnectionState(.playing(episode))
        XCTAssertFalse(
            manager.viewModel.staticItemsProvider().contains { $0.id == CommandPaletteCommandID.toggleLyrics }
        )

        let track = PlaybackNowPlaying(
            name: "Song",
            artists: ["Artist"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 100,
            positionMilliseconds: 0,
            uri: "spotify:track:1"
        )
        playback.setConnectionState(.playing(track))
        XCTAssertTrue(
            manager.viewModel.staticItemsProvider().contains { $0.id == CommandPaletteCommandID.toggleLyrics }
        )
        manager.execute(commandID: CommandPaletteCommandID.toggleLyrics)
        XCTAssertEqual(dispatchCount, 1)
    }

    func testPlaybackTogglePaletteItemTracksReadiness() async {
        let manager = CommandPaletteManager()
        manager.isSignedIn = true
        manager.setPlaybackToggleAvailability(true)
        manager.viewModel.show()
        manager.viewModel.query = ">"
        manager.viewModel.refresh()
        await manager.viewModel.waitForSearchCompletion()
        XCTAssertTrue(manager.viewModel.visibleItems.contains { $0.id == CommandPaletteCommandID.togglePlayback })

        manager.setPlaybackToggleAvailability(false)
        await manager.viewModel.waitForSearchCompletion()
        XCTAssertFalse(manager.viewModel.visibleItems.contains { $0.id == CommandPaletteCommandID.togglePlayback })
    }

    func testUnavailablePlaybackToggleSelectionDoesNotDismissOrDispatch() async {
        let manager = CommandPaletteManager()
        manager.isSignedIn = true
        manager.setPlaybackToggleAvailability(true)
        var prerequisite = true
        manager.playbackTogglePrerequisite = { prerequisite }
        var dispatchCount = 0
        manager.togglePlayback = { dispatchCount += 1 }
        manager.viewModel.show()
        manager.viewModel.query = ">play"
        manager.viewModel.refresh()
        await manager.viewModel.waitForSearchCompletion()
        prerequisite = false

        await manager.viewModel.executeSelection()

        XCTAssertTrue(manager.viewModel.isPresented)
        XCTAssertEqual(dispatchCount, 0)
    }

    func testPlaybackToggleAvailabilityFollowsPlaybackLifecycleAndRemoteRouting() {
        let manager = CommandPaletteManager()
        let playback = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander()
        )
        manager.bindPlaybackReadiness(to: playback)
        XCTAssertFalse(manager.canTogglePlayback)

        playback.deviceID = "local-device"
        playback.setConnectionState(.ready(deviceID: "local-device"))
        XCTAssertTrue(manager.canTogglePlayback)

        playback.setActivePlaybackDeviceID("remote-device")
        XCTAssertTrue(manager.canTogglePlayback)
        playback.setActivePlaybackDeviceID("local-device")
        XCTAssertTrue(manager.canTogglePlayback)

        playback.setConnectionState(.unavailable("offline"))
        XCTAssertFalse(manager.canTogglePlayback)
    }

    func testPlaybackToggleDispatchesForReadyPausedAndPlayingLocalStates() async {
        let manager = CommandPaletteManager()
        let playback = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander()
        )
        playback.deviceID = "local-device"
        manager.bindPlaybackReadiness(to: playback)
        manager.playbackTogglePrerequisite = { playback.isPlaybackToggleReady }
        let dispatched = expectation(description: "local playback toggles")
        dispatched.expectedFulfillmentCount = 3
        manager.togglePlayback = { dispatched.fulfill() }
        let track = PlaybackNowPlaying(
            name: "Song",
            artists: ["A"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 100,
            positionMilliseconds: 0,
            uri: "spotify:track:1"
        )

        for state in [
            PlaybackConnectionState.ready(deviceID: "local-device"),
            .paused(track),
            .playing(track)
        ] {
            playback.setConnectionState(state)
            manager.execute(commandID: CommandPaletteCommandID.togglePlayback)
        }

        await fulfillment(of: [dispatched], timeout: 2)
    }

}
