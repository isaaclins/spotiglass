import AppKit
import SwiftUI
import ViewInspector
import XCTest
@testable import Spotiglass

/// The palette as one panel near the top of the window (#472, #462, #469): what it offers before
/// typing, how it fits a short window, and how the selected filter reads.
@MainActor
final class CommandPalettePanelTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    private func command(_ id: String, title: String) -> CommandPaletteItem {
        CommandPaletteItem(id: id, title: title, subtitle: nil, iconSystemName: "command", section: .commands, keywords: []) {}
    }

    private func track(_ index: Int) -> CommandPaletteItem {
        CommandPaletteItem(
            id: "track-\(index)",
            title: "Song \(index)",
            subtitle: "Artist \(index)",
            iconSystemName: "music.note",
            section: .tracks,
            keywords: []
        ) {}
    }

    // MARK: - Before typing

    /// Opening the palette showed a lone field: nothing to pick before typing (#472).
    func testOpeningThePaletteOffersRecentSearchesAndQuickActions() {
        let viewModel = CommandPaletteViewModel()
        viewModel.recentSearches = .inMemory(["daft punk", "midnight city"])
        viewModel.staticItemsProvider = { [unowned self] in
            [
                command(CommandPaletteCommandID.openSettings, title: "Open Settings"),
                command(CommandPaletteCommandID.refreshPlaylists, title: "Refresh"),
                command(CommandPaletteCommandID.togglePlayback, title: "Play/Pause")
            ]
        }

        viewModel.show()

        XCTAssertEqual(viewModel.sections.map(\.section), [.recentSearches, .quickActions])
        XCTAssertEqual(viewModel.sections[0].items.map(\.title), ["daft punk", "midnight city"])
        // Quick actions follow the fixed everyday order and skip commands the host doesn't list.
        XCTAssertEqual(
            viewModel.sections[1].items.map(\.id),
            [CommandPaletteCommandID.togglePlayback, CommandPaletteCommandID.openSettings]
        )
    }

    func testClearingTheQueryBringsTheSuggestionsBack() async {
        let viewModel = CommandPaletteViewModel()
        viewModel.recentSearches = .inMemory(["daft punk"])
        viewModel.show()
        viewModel.query = "da"
        viewModel.refresh()
        await viewModel.waitForSearchCompletion()
        XCTAssertFalse(viewModel.sections.contains { $0.section == .recentSearches })

        viewModel.query = ""
        viewModel.refresh()
        await viewModel.waitForSearchCompletion()
        XCTAssertEqual(viewModel.sections.map(\.section), [.recentSearches])
    }

    func testASearchThatLedToAResultBecomesARecentSearch() async {
        let viewModel = CommandPaletteViewModel()
        let recents = CommandPaletteRecentSearches.inMemory(["older", "Midnight City"])
        viewModel.recentSearches = recents
        viewModel.show()
        viewModel.query = "  midnight city "
        viewModel.testingReplaceSections([(.tracks, [track(1)])])

        await viewModel.executeSelection()

        // Newest first, once, whatever its case or spaces.
        XCTAssertEqual(recents.queries, ["midnight city", "older"])
    }

    func testCommandsAndOneLetterQueriesAreNotRecorded() async {
        let viewModel = CommandPaletteViewModel()
        let recents = CommandPaletteRecentSearches.inMemory()
        viewModel.recentSearches = recents
        viewModel.show()
        viewModel.query = ">settings"
        viewModel.testingReplaceSections([(.commands, [command("x", title: "Open Settings")])])
        await viewModel.executeSelection()
        viewModel.show()
        viewModel.query = "m"
        viewModel.testingReplaceSections([(.tracks, [track(1)])])
        await viewModel.executeSelection()

        XCTAssertEqual(recents.queries, [])
    }

    func testRecentSearchesKeepTheNewestFive() {
        let recents = CommandPaletteRecentSearches.inMemory()
        for query in ["a1", "a2", "a3", "a4", "a5", "a6"] {
            recents.record(query)
        }
        XCTAssertEqual(recents.queries, ["a6", "a5", "a4", "a3", "a2"])
    }

    func testPickingARecentSearchRunsItAndKeepsThePaletteOpen() async {
        let viewModel = CommandPaletteViewModel()
        viewModel.recentSearches = .inMemory(["daft punk"])
        var searched: [String] = []
        viewModel.searchProvider = { query, _ in
            searched.append(query)
            return CommandPaletteSearchResults(tracks: [self.track(1)])
        }
        viewModel.show()

        await viewModel.executeSelection()
        await viewModel.waitForSearchCompletion()

        XCTAssertTrue(viewModel.isPresented)
        XCTAssertEqual(viewModel.query, "daft punk")
        XCTAssertEqual(searched, ["daft punk"])
        XCTAssertEqual(viewModel.sections.first?.section, .tracks)
    }

    func testRecentSearchesInTheDefaultsAreSharedByEveryWindow() {
        let defaults = makeEphemeralDefaults()
        let first = CommandPaletteRecentSearches.userDefaults(defaults)
        let second = CommandPaletteRecentSearches.userDefaults(defaults)
        first.record("daft punk")
        XCTAssertEqual(second.queries, ["daft punk"])
        XCTAssertEqual(defaults.stringArray(forKey: CommandPaletteRecentSearches.defaultsKey), ["daft punk"])
    }

    // MARK: - Short window (#462)

    /// At 900 × 450 the results took a fixed 360 pt and pushed the filters and the key hints out
    /// of the window. The palette now fits the window and the list scrolls inside it.
    func testThePaletteFitsAShortWindowWithManyResults() throws {
        let store = try ViewTestHost.makeSettingsStore()
        let viewModel = CommandPaletteViewModel()
        viewModel.show()
        viewModel.query = "song"
        let showAll = CommandPaletteItem(
            id: "palette.showAllResults", title: "Show all results", subtitle: nil,
            iconSystemName: "magnifyingglass", section: .showAll, keywords: []
        ) {}
        viewModel.testingReplaceSections([(.tracks, (0 ..< 30).map(track)), (.showAll, [showAll])])

        let controller = NSHostingController(rootView: CommandPaletteView(viewModel: viewModel).environmentObject(store))
        for window in [CGSize(width: 900, height: 450), CGSize(width: 640, height: 400)] {
            let fitted = controller.sizeThatFits(in: window)
            XCTAssertLessThanOrEqual(fitted.height, window.height, "palette taller than a \(window) window")
        }
    }

    // MARK: - Selected filter (#469)

    /// The selected chip drew a fixed white label on the accent, and the accent turns white while
    /// the window is not the active one: a white blob with no label.
    func testTheSelectedFilterKeepsItsLabelInAnInactiveWindow() throws {
        for scheme in [ColorScheme.dark, .light] {
            for active in [true, false] {
                let viewModel = CommandPaletteViewModel()
                viewModel.show()
                let chip = CommandPaletteCategoryPillView(category: .all, viewModel: viewModel)
                    .environment(\.appearsActive, active)
                    .environment(\.colorScheme, scheme)
                    .padding(SpotiglassDesign.spacingXS)
                let renderer = ImageRenderer(content: chip)
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.cgImage)
                let contrast = try XCTUnwrap(Self.labelContrast(in: image))
                XCTAssertGreaterThan(contrast, 0.35, "label unreadable on the selected chip (\(scheme), active \(active))")
            }
        }
    }

    /// The spread between the fill (the most common opaque luminance) and the pixels furthest from it.
    private static func labelContrast(in image: CGImage) -> Double? {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var buckets = [Int](repeating: 0, count: 21)
        var lumas: [Double] = []
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 250 {
            let luma = (0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])) / 255
            lumas.append(luma)
            buckets[Int((luma * 20).rounded())] += 1
        }
        guard let fillBucket = buckets.indices.max(by: { buckets[$0] < buckets[$1] }) else { return nil }
        let fill = Double(fillBucket) / 20
        // Ignore the stray few per cent of anti-aliasing: the label must cover real pixels.
        let far = lumas.map { abs($0 - fill) }.sorted(by: >)
        guard !far.isEmpty else { return nil }
        return far[min(far.count - 1, far.count / 50)]
    }
}
