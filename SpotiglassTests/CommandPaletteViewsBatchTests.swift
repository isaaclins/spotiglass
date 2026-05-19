import SwiftUI
import ViewInspector
import XCTest
@testable import Spotiglass

@MainActor
final class CommandPaletteViewsBatchTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    private func makeHarness() throws -> (
        SpotiglassSettingsStore,
        CommandPaletteKeymapStore,
        CommandPaletteManager
    ) {
        let url = makeCommandPaletteTestsTempSettingsURL()
        let settings = SpotiglassSettingsStore(fileURL: url)
        let keymap = CommandPaletteKeymapStore(settingsStore: settings)
        let manager = CommandPaletteManager(keymapStore: keymap)
        return (settings, keymap, manager)
    }

    private func sampleItem(
        id: String = "item-1",
        section: CommandPaletteSection = .tracks,
        title: String = "Midnight City"
    ) -> CommandPaletteItem {
        CommandPaletteItem(
            id: id,
            title: title,
            subtitle: "M83",
            iconSystemName: "music.note",
            trackArtworkURL: URL(string: "https://example.com/art.jpg"),
            section: section,
            keywords: [title.lowercased()],
            isExplicit: true,
            action: {}
        )
    }

    func testSettingsViewStandaloneAndTabs() throws {
        let (_, keymap, manager) = try makeHarness()
        let standalone = CommandPaletteSettingsView(
            keymapStore: keymap,
            commandPaletteManager: manager,
            presentation: .standalone
        )
        ViewTestHost.host(standalone, size: CGSize(width: 760, height: 560))
        XCTAssertNoThrow(try standalone.inspect().find(text: "Command Palette Keymap"))

        let tabs = CommandPaletteSettingsView(
            keymapStore: keymap,
            commandPaletteManager: manager,
            presentation: .settingsTabs
        )
        ViewTestHost.host(tabs, size: CGSize(width: 760, height: 560))
        XCTAssertNoThrow(try tabs.inspect().find(text: "Shortcuts"))
    }

    func testBackdropBlurVariants() throws {
        var dismissed = false
        let blurred = CommandPaletteBackdropView(
            backdropBlur: true,
            materialOpacity: 0.55,
            onDismiss: { dismissed = true }
        )
        ViewTestHost.host(blurred, size: CGSize(width: 400, height: 300))
        XCTAssertNoThrow(try blurred.inspect())

        let clear = CommandPaletteBackdropView(
            backdropBlur: false,
            materialOpacity: 0.55,
            onDismiss: { dismissed = true }
        )
        ViewTestHost.host(clear)
        XCTAssertNoThrow(try clear.inspect())
        XCTAssertFalse(dismissed)
    }

    func testResultRowArtistAndTrackArtwork() throws {
        let trackRow = CommandPaletteResultRowView(item: sampleItem())
        ViewTestHost.host(trackRow)
        XCTAssertNoThrow(try trackRow.inspect().find(text: "Midnight City"))
        XCTAssertNoThrow(try trackRow.inspect().find(text: "Explicit"))

        let artistItem = CommandPaletteItem(
            id: "a1",
            title: "M83",
            subtitle: "Artist",
            iconSystemName: "person.fill",
            artistAvatarURL: nil,
            section: .artists,
            keywords: ["m83"],
            action: {}
        )
        let artistRow = CommandPaletteResultRowView(item: artistItem)
        ViewTestHost.host(artistRow)
        XCTAssertNoThrow(try artistRow.inspect().find(text: "M83"))

        let avatar = CommandPaletteArtistAvatar(
            imageURL: nil,
            fallbackSystemName: "person.fill"
        )
        ViewTestHost.host(avatar)
        XCTAssertNoThrow(try avatar.inspect())

        let trackArt = CommandPaletteTrackArtwork(
            imageURL: URL(string: "https://example.com/t.jpg")!,
            fallbackSystemName: "music.note"
        )
        ViewTestHost.host(trackArt)
        XCTAssertNoThrow(try trackArt.inspect())
    }

    func testResultsBodyStates() throws {
        let vm = CommandPaletteViewModel()
        vm.show()

        vm.testingReplaceSections([
            (.tracks, [sampleItem()]),
            (.commands, [
                CommandPaletteItem(
                    id: "cmd",
                    title: "Refresh",
                    subtitle: nil,
                    iconSystemName: "arrow.clockwise",
                    section: .commands,
                    keywords: [],
                    action: {}
                ),
            ]),
        ])
        let body = CommandPaletteResultsBodyView(
            viewModel: vm,
            accessibilityReduceMotion: true
        )
        ViewTestHost.host(body, size: CGSize(width: 700, height: 400))
        XCTAssertNoThrow(try body.inspect())

        vm.testingReplaceSections([])
        vm.query = "zzz"
        let empty = CommandPaletteResultsBodyView(viewModel: vm, accessibilityReduceMotion: true)
        ViewTestHost.host(empty, size: CGSize(width: 700, height: 400))
        XCTAssertNoThrow(try empty.inspect().find(text: "No results for \"zzz\""))

        let loading = CommandPaletteSearchingPlaceholderView(accessibilityReduceMotion: true)
        ViewTestHost.host(loading, size: CGSize(width: 400, height: 200))
        XCTAssertNoThrow(try loading.inspect())
    }

    func testPrefetchProgressHeaderPhases() throws {
        let running = CommandPalettePrefetchProgressHeader(
            progress: PrefetchAllPlaylistsProgress(
                phase: .running, total: 10, completed: 2, skipped: 1, failed: 0
            ),
            onCancel: {}
        )
        ViewTestHost.host(running)
        XCTAssertNoThrow(try running.inspect().find(text: "Loading 3 of 10 playlists…"))

        let finished = CommandPalettePrefetchProgressHeader(
            progress: PrefetchAllPlaylistsProgress(
                phase: .finished, total: 5, completed: 4, skipped: 1, failed: 0
            ),
            onCancel: {}
        )
        ViewTestHost.host(finished)
        XCTAssertNoThrow(try finished.inspect())
    }

    func testFooterAndHints() throws {
        let vm = CommandPaletteViewModel()
        vm.show()
        struct FooterHost: View {
            @Namespace private var glass
            @ObservedObject var viewModel: CommandPaletteViewModel
            var body: some View {
                CommandPaletteFooterView(viewModel: viewModel, paletteGlass: glass)
            }
        }
        ViewTestHost.host(FooterHost(viewModel: vm))
        XCTAssertNoThrow(try FooterHost(viewModel: vm).inspect().find(text: "↑↓ navigate"))
    }

    func testHotkeyRecorderFieldHosts() throws {
        let (_, keymap, manager) = try makeHarness()
        let spec = CommandPaletteCommandCatalog.editable.first!
        let field = HotkeyRecorderField(
            commandID: spec.commandID,
            keymapStore: keymap,
            onRecordingChange: { manager.isRecordingHotkey = $0 },
            onCaptureConflict: { _, _ in },
            onApplied: {}
        )
        ViewTestHost.host(field.frame(width: 200, height: 28))
        XCTAssertNotNil(field)
    }
}
