import AppKit
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
        let (_, keymap, _) = try makeHarness()
        let standalone = CommandPaletteSettingsView(
            keymapStore: keymap,
            presentation: .standalone
        )
        ViewTestHost.host(standalone, size: CGSize(width: 760, height: 560))
        XCTAssertNoThrow(try standalone.inspect().find(text: "Command Palette Keymap"))

        let tabs = CommandPaletteSettingsView(
            keymapStore: keymap,
            presentation: .settingsTabs
        )
        ViewTestHost.host(tabs, size: CGSize(width: 760, height: 560))
        XCTAssertNoThrow(try tabs.inspect().find(text: "Shortcuts"))
    }

    /// Bound and unbound rows used to end on different lines: an unbound row had
    /// no clear button, so its trailing-aligned field sat further right (#428).
    /// Checked in the window's standalone layout and in the Settings pane's Form.
    func testKeyboardRowsKeepOneShortcutColumnWhetherBoundOrNot() throws {
        let (_, keymap, _) = try makeHarness()
        try keymap.clearBinding(commandID: CommandPaletteCommandID.nextTrack)
        XCTAssertNil(keymap.primaryShortcut(for: CommandPaletteCommandID.nextTrack))
        let bindable = CommandPaletteCommandCatalog.editable.filter { !$0.isDestructive }

        for presentation in [CommandPaletteSettingsView.Presentation.standalone, .settingsTabs] {
            let controller = ViewTestHost.host(
                CommandPaletteSettingsView(keymapStore: keymap, presentation: presentation),
                size: CGSize(width: 760, height: 1_600)
            )
            let fields = recorderFields(in: controller.view)
            XCTAssertEqual(fields.count, bindable.count, "\(presentation): one recorder per bindable command")
            let frames = fields.map { $0.convert($0.bounds, to: nil) }
            for frame in frames {
                XCTAssertEqual(frame.width, SpotiglassDesign.Layout.shortcutFieldWidth, accuracy: 0.5, "\(presentation)")
                XCTAssertEqual(frame.minX, frames[0].minX, accuracy: 0.5, "\(presentation): a shortcut field left the column")
            }
        }
    }

    /// The "Not bindable" row used to show loose text with a lock where the
    /// field goes. It now takes the same column as every other row.
    func testNotBindableRowTakesTheSameShortcutColumn() throws {
        let (_, keymap, _) = try makeHarness()
        let view = CommandPaletteSettingsView(keymapStore: keymap, presentation: .standalone)
        ViewTestHost.host(view, size: CGSize(width: 760, height: 1_600))

        let columns = try view.inspect().findAll(where: {
            (try? $0.fixedWidth()) == SpotiglassDesign.Layout.shortcutFieldWidth
        })
        XCTAssertEqual(columns.count, CommandPaletteCommandCatalog.editable.count, "one shortcut column per row")
        let notBindable = SpotiglassL10n.string("palette.settings.notBindable")
        let destructive = CommandPaletteCommandCatalog.editable.filter(\.isDestructive).count
        XCTAssertGreaterThan(destructive, 0)
        XCTAssertEqual(
            columns.filter { (try? $0.find(text: notBindable)) != nil }.count, destructive,
            "every not-bindable row shows its notice inside the shortcut column"
        )
    }

    /// The field has one width for every row, so it has to fit the longest
    /// state in every language the app ships, or German would clip.
    func testShortcutFieldFitsEveryStateInEveryLanguage() {
        for language in ["en", "de", "es"] {
            let locale = Locale(identifier: language)
            let recording = SpotiglassL10n.string("palette.hotkeyRecorder.recording", locale: locale)
            let states = [
                SpotiglassL10n.string("palette.hotkeyRecorder.clickToRecord", locale: locale),
                "\(recording)  ⌃ ⌥ ⇧ ⌘",
                SpotiglassL10n.string("palette.settings.notBindable", locale: locale),
            ]
            for state in states {
                let button = NSButton(title: state, target: nil, action: nil)
                button.bezelStyle = .rounded
                XCTAssertLessThanOrEqual(
                    button.fittingSize.width, SpotiglassDesign.Layout.shortcutFieldWidth,
                    "\(language): \"\(state)\" doesn't fit the shortcut field"
                )
            }
        }
    }

    private func recorderFields(in view: NSView) -> [RecorderKeyContainerView] {
        (view as? RecorderKeyContainerView).map { [$0] } ?? view.subviews.flatMap { recorderFields(in: $0) }
    }

    func testSettingsViewSurfacesCrossContextDuplicate() throws {
        let (_, keymap, _) = try makeHarness()
        try keymap.setBinding(
            commandID: CommandPaletteCommandID.openSearch,
            shortcut: try CommandShortcut(keystroke: "cmd-return"),
            replaceConflicting: false
        )
        let view = CommandPaletteSettingsView(
            keymapStore: keymap,
            presentation: .standalone
        )
        ViewTestHost.host(view, size: CGSize(width: 760, height: 560))

        let expected = SpotiglassL10n.format(
            "palette.settings.alsoUsed",
            SpotiglassL10n.string("palette.command.\(CommandPaletteCommandID.pinSelected).title"),
            SpotiglassL10n.string("palette.settings.context.paletteOpen")
        )
        XCTAssertNoThrow(try view.inspect().find(text: expected))
    }

    func testBackdropBlurVariants() throws {
        var dismissed = false
        let blurred = CommandPaletteBackdropView(
            backdropBlur: true,
            onDismiss: { dismissed = true }
        )
        ViewTestHost.host(blurred, size: CGSize(width: 400, height: 300))
        XCTAssertNoThrow(try blurred.inspect())

        let clear = CommandPaletteBackdropView(
            backdropBlur: false,
            onDismiss: { dismissed = true }
        )
        ViewTestHost.host(clear)
        XCTAssertNoThrow(try clear.inspect())
        XCTAssertFalse(dismissed)
    }

    /// Selection was carried by a list row background only, and the row broke
    /// into icon plus title plus "Explicit" plus subtitle fragments, so nothing
    /// about the current result was available to assistive technology (#119).
    func testResultRowIsOneLabelledElementThatReportsSelection() throws {
        let item = sampleItem()
        let label = CommandPaletteResultRowView.accessibilityLabel(for: item)
        XCTAssertTrue(label.contains("Midnight City"), "expected the title in the label, got \(label)")
        XCTAssertTrue(label.contains("Explicit"), "expected the badge in the label, got \(label)")
        XCTAssertTrue(label.contains(try XCTUnwrap(item.subtitle)), "expected the subtitle, got \(label)")

        // Selection changes the trait, not the words.
        let selected = CommandPaletteResultRowView(item: item, isSelected: true)
        ViewTestHost.host(selected)
        XCTAssertNoThrow(try selected.inspect())

        let unselected = CommandPaletteResultRowView(item: item, isSelected: false)
        ViewTestHost.host(unselected)
        XCTAssertNoThrow(try unselected.inspect())
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

        vm.testingReplaceSections([])
        vm.query = ">"
        let prefixOnly = CommandPaletteResultsBodyView(viewModel: vm, accessibilityReduceMotion: true)
        ViewTestHost.host(prefixOnly, size: CGSize(width: 700, height: 400))
        XCTAssertNoThrow(try prefixOnly.inspect())

        let animatedSearch = CommandPaletteSearchingPlaceholderView(accessibilityReduceMotion: false)
        ViewTestHost.host(animatedSearch, size: CGSize(width: 400, height: 200))
        XCTAssertNoThrow(try animatedSearch.inspect())
    }

    func testSectionedListTapAndIconLeading() throws {
        let vm = CommandPaletteViewModel()
        vm.show()
        let iconOnly = CommandPaletteItem(
            id: "cmd-icon",
            title: "Settings",
            subtitle: nil,
            iconSystemName: "gear",
            section: .commands,
            keywords: [],
            action: {}
        )
        vm.testingReplaceSections([(.commands, [iconOnly, sampleItem()])])
        vm.selectedIndex = 1
        let list = CommandPaletteSectionedListView(
            viewModel: vm,
            sections: vm.sections,
            accessibilityReduceMotion: false
        )
        ViewTestHost.host(list, size: CGSize(width: 700, height: 400))
        // The list is lazy, which ViewInspector can't search: check the row it builds instead.
        let row = CommandPaletteResultRowView(item: iconOnly, isSelected: false)
        XCTAssertNoThrow(try row.inspect().find(text: "Settings"))

        let leading = CommandPaletteRowLeadingView(item: iconOnly)
        ViewTestHost.host(leading)
        XCTAssertNoThrow(try leading.inspect().find(ViewType.Image.self))
    }

    func testPrefetchProgressHeaderPhases() throws {
        let preparing = CommandPalettePrefetchProgressHeader(
            progress: PrefetchAllPlaylistsProgress(
                phase: .running, total: 0, completed: 0, skipped: 0, failed: 0
            ),
            onCancel: {}
        )
        ViewTestHost.host(preparing)
        XCTAssertNoThrow(try preparing.inspect().find(text: "Preparing…"))

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
        XCTAssertNoThrow(try finished.inspect().find(text: "Loaded 5 playlists"))

        let partialFail = CommandPalettePrefetchProgressHeader(
            progress: PrefetchAllPlaylistsProgress(
                phase: .finished, total: 5, completed: 3, skipped: 1, failed: 1
            ),
            onCancel: {}
        )
        ViewTestHost.host(partialFail)
        XCTAssertNoThrow(try partialFail.inspect())

        let cancelled = CommandPalettePrefetchProgressHeader(
            progress: PrefetchAllPlaylistsProgress(
                phase: .cancelled, total: 8, completed: 2, skipped: 0, failed: 0
            ),
            onCancel: {}
        )
        ViewTestHost.host(cancelled)
        XCTAssertNoThrow(try cancelled.inspect().find(text: "Prefetch cancelled (2 of 8)"))
    }

    func testFooterAndHints() throws {
        let vm = CommandPaletteViewModel()
        vm.show()
        struct FooterHost: View {
            @ObservedObject var viewModel: CommandPaletteViewModel
            var body: some View {
                CommandPaletteFooterView(viewModel: viewModel)
            }
        }
        ViewTestHost.host(FooterHost(viewModel: vm))
        XCTAssertNoThrow(try FooterHost(viewModel: vm).inspect().find(text: "↑↓ navigate"))
    }

    func testResultsCardPrefetchAndError() async throws {
        let vm = CommandPaletteViewModel()
        vm.show()
        vm.prefetchProgress = PrefetchAllPlaylistsProgress(
            phase: .running, total: 4, completed: 1, skipped: 0, failed: 0
        )
        struct CardHost: View {
            @ObservedObject var viewModel: CommandPaletteViewModel
            var body: some View {
                CommandPaletteResultsCardView(
                    viewModel: viewModel,
                    accessibilityReduceMotion: true
                )
            }
        }
        let host = CardHost(viewModel: vm)
        ViewTestHost.host(host, size: CGSize(width: 700, height: 420))
        XCTAssertNoThrow(try host.inspect())

        vm.searchProvider = { _, _ in
            throw SpotifyAPIError.server(statusCode: 500, message: "err", details: nil)
        }
        vm.query = "ab"
        vm.refresh()
        await vm.waitForSearchCompletion()
        XCTAssertNotNil(vm.errorText)
        ViewTestHost.host(host, size: CGSize(width: 700, height: 420))
        XCTAssertNoThrow(try host.inspect())
    }

}
