import XCTest
@testable import Spotiglass

/// Keeps the app on one layout grid (#428).
///
/// Views used to pick their own spacing numbers next to an off-grid token scale
/// (6, 10, 16, 24, 36), so edges and centre lines drifted between sections. The
/// scale and the shared layout values now live in `SpotiglassDesign`, and these
/// tests fail as soon as a view goes back to a number of its own.
final class LayoutGridTests: XCTestCase {
    // MARK: - The scale

    func testSpacingScaleSitsOnTheFourPointGrid() {
        let scale = [
            SpotiglassDesign.spacingXXS,
            SpotiglassDesign.spacingXS,
            SpotiglassDesign.spacingS,
            SpotiglassDesign.spacingM,
            SpotiglassDesign.spacingL,
            SpotiglassDesign.spacingXL,
        ]
        XCTAssertEqual(scale, [4, 8, 12, 16, 24, 32])
        XCTAssertEqual(scale, scale.sorted(), "the scale has to grow step by step")
        for value in scale {
            XCTAssertEqual(
                value.truncatingRemainder(dividingBy: SpotiglassDesign.gridUnit), 0,
                "\(value) is off the \(SpotiglassDesign.gridUnit) pt grid"
            )
        }
        // The one half step, for the gap inside a single label (title over
        // subtitle, a badge's vertical inset), is exactly half a grid unit.
        XCTAssertEqual(SpotiglassDesign.spacingHalf * 2, SpotiglassDesign.gridUnit)
    }

    /// Every shared layout value. Add new ones here too.
    private static let layoutValues: [(String, CGFloat)] = [
        ("contentMargin", SpotiglassDesign.Layout.contentMargin),
        ("insetListMargin", SpotiglassDesign.Layout.insetListMargin),
        ("insetListContentInset", SpotiglassDesign.Layout.insetListContentInset),
        ("sectionSpacing", SpotiglassDesign.Layout.sectionSpacing),
        ("sectionTitleSpacing", SpotiglassDesign.Layout.sectionTitleSpacing),
        ("panelMargin", SpotiglassDesign.Layout.panelMargin),
        ("trackRowHeight", SpotiglassDesign.Layout.trackRowHeight),
        ("trackRowArtworkSize", SpotiglassDesign.Layout.trackRowArtworkSize),
        ("trackNumberColumnWidth", SpotiglassDesign.Layout.trackNumberColumnWidth),
        ("durationColumnWidth", SpotiglassDesign.Layout.durationColumnWidth),
        ("sidebarRowArtworkSize", SpotiglassDesign.Layout.sidebarRowArtworkSize),
        ("smallArtworkSize", SpotiglassDesign.Layout.smallArtworkSize),
        ("thumbnailSize", SpotiglassDesign.Layout.thumbnailSize),
        ("compactRowArtworkSize", SpotiglassDesign.Layout.compactRowArtworkSize),
        ("dragPreviewMaxWidth", SpotiglassDesign.Layout.dragPreviewMaxWidth),
        ("nowPlayingArtworkSize", SpotiglassDesign.Layout.nowPlayingArtworkSize),
        ("quickAccessTileHeight", SpotiglassDesign.Layout.quickAccessTileHeight),
        ("quickAccessTileMinWidth", SpotiglassDesign.Layout.quickAccessTileMinWidth),
        ("sectionNoticeMinHeight", SpotiglassDesign.Layout.sectionNoticeMinHeight),
        ("cardWidth", SpotiglassDesign.Layout.cardWidth),
        ("lyricsArtworkSize", SpotiglassDesign.Layout.lyricsArtworkSize),
        ("lyricsStatusMinHeight", SpotiglassDesign.Layout.lyricsStatusMinHeight),
        ("lyricsInstrumentalMinHeight", SpotiglassDesign.Layout.lyricsInstrumentalMinHeight),
        ("lyricsSideColumnMaxWidth", SpotiglassDesign.Layout.lyricsSideColumnMaxWidth),
        ("lyricsColumnMinHeight", SpotiglassDesign.Layout.lyricsColumnMinHeight),
        ("serviceChoiceLogoSize", SpotiglassDesign.Layout.serviceChoiceLogoSize),
        ("serviceChoiceWidth", SpotiglassDesign.Layout.serviceChoiceWidth),
        ("iconButtonSize", SpotiglassDesign.Layout.iconButtonSize),
        ("inlineButtonSize", SpotiglassDesign.Layout.inlineButtonSize),
        ("iconSize", SpotiglassDesign.Layout.iconSize),
        ("timeLabelMinWidth", SpotiglassDesign.Layout.timeLabelMinWidth),
        ("wideButtonWidth", SpotiglassDesign.Layout.wideButtonWidth),
        ("valueLabelMinWidth", SpotiglassDesign.Layout.valueLabelMinWidth),
        ("messageMaxWidth", SpotiglassDesign.Layout.messageMaxWidth),
        ("paragraphMaxWidth", SpotiglassDesign.Layout.paragraphMaxWidth),
        ("panelMaxWidth", SpotiglassDesign.Layout.panelMaxWidth),
        ("breadcrumbMaxWidth", SpotiglassDesign.Layout.breadcrumbMaxWidth),
        ("toolbarProgressWidth", SpotiglassDesign.Layout.toolbarProgressWidth),
        ("pickerMaxWidth", SpotiglassDesign.Layout.pickerMaxWidth),
        ("gainLabelWidth", SpotiglassDesign.Layout.gainLabelWidth),
        ("equalizerBandMinWidth", SpotiglassDesign.Layout.equalizerBandMinWidth),
        ("equalizerSliderHeight", SpotiglassDesign.Layout.equalizerSliderHeight),
        ("sheetWidth", SpotiglassDesign.Layout.sheetWidth),
        ("shortcutFieldMinWidth", SpotiglassDesign.Layout.shortcutFieldMinWidth),
        ("textEditorMinHeight", SpotiglassDesign.Layout.textEditorMinHeight),
        ("standaloneSettingsMinWidth", SpotiglassDesign.Layout.standaloneSettingsMinWidth),
        ("standaloneSettingsMinHeight", SpotiglassDesign.Layout.standaloneSettingsMinHeight),
        ("paletteMaxWidth", SpotiglassDesign.Layout.paletteMaxWidth),
        ("paletteResultsHeight", SpotiglassDesign.Layout.paletteResultsHeight),
        ("paletteProgressMaxWidth", SpotiglassDesign.Layout.paletteProgressMaxWidth),
        ("settingsWindowWidth", SpotiglassDesign.settingsWindowWidth),
        ("settingsWindowMinHeight", SpotiglassDesign.settingsWindowMinHeight),
        ("settingsSidebarMinWidth", SpotiglassDesign.settingsSidebarMinWidth),
        ("settingsSidebarIdealWidth", SpotiglassDesign.settingsSidebarIdealWidth),
        ("settingsSidebarMaxWidth", SpotiglassDesign.settingsSidebarMaxWidth),
        ("settingsProfileAvatarSize", SpotiglassDesign.settingsProfileAvatarSize),
        ("settingsHeaderIconSize", SpotiglassDesign.settingsHeaderIconSize),
        ("settingsSidebarIconSize", SpotiglassDesign.settingsSidebarIconSize),
        ("detailHeaderArtworkSize", SpotiglassDesign.detailHeaderArtworkSize),
        ("sidebarWidth", SpotiglassDesign.sidebarWidth),
        ("playlistSidebarMinWidth", SpotiglassDesign.playlistSidebarMinWidth),
        ("detailColumnMinWidth", SpotiglassDesign.detailColumnMinWidth),
        ("queuePanelMinWidth", SpotiglassDesign.queuePanelMinWidth),
        ("queuePanelMaxWidth", SpotiglassDesign.queuePanelMaxWidth),
    ]

    func testSharedLayoutValuesSitOnTheGrid() {
        for (name, value) in Self.layoutValues {
            XCTAssertEqual(
                value.truncatingRemainder(dividingBy: SpotiglassDesign.gridUnit), 0,
                "\(name) is \(value), off the \(SpotiglassDesign.gridUnit) pt grid"
            )
        }
    }

    /// Rows that render a track fill their height exactly: artwork plus the
    /// row's own padding. Before, the padding (2 x 6) left 4 pt of slack, so
    /// the artwork sat a little off the row's centre line.
    func testTrackRowHeightIsArtworkPlusPadding() {
        XCTAssertEqual(
            TrackListRow.listRowHeight,
            TrackRowMetrics.artworkSize + 2 * TrackRowMetrics.verticalPadding
        )
    }

    // MARK: - No loose numbers in views

    func testViewsUseNoLooseSpacingNumbers() throws {
        let findings = try Self.looseLayoutNumbers()
        XCTAssertTrue(
            findings.isEmpty,
            """
            These lines use their own spacing or size numbers. Use a token from \
            SpotiglassDesign (spacing scale or SpotiglassDesign.Layout) instead:
            \(findings.joined(separator: "\n"))
            """
        )
    }

    /// The scanner itself has to catch every shape a loose number takes in a
    /// view, or the test above passes for the wrong reason.
    func testScannerFlagsEveryLooseShape() {
        let flagged = [
            "VStack(alignment: .leading, spacing: 4) {",
            ".padding(6)",
            ".padding(.horizontal, 10)",
            ".padding([.top, .leading], 12)",
            ".padding(.leading, 28 + SpotiglassDesign.spacingM)",
            ".frame(width: 150, alignment: .leading)",
            ".frame(maxWidth: 420)",
            ".frame(minHeight: 60)",
            ".offset(x: -6, y: -6)",
            ".listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))",
            "Spacer(minLength: 8)",
            "stack.spacing = 10",
            "stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 8)",
            ".spotiglassPillBackground(variant: .plain, horizontalPadding: 10, verticalPadding: 6)",
            "ArtworkView(url: card.artworkURL, size: 150)",
            "GridItem(.adaptive(minimum: 220), spacing: 10)",
            ".frame(maxWidth: layout == .welcome ? 420 : .infinity)",
            ".padding(.top, ImmersiveLyricsLayout.minimumTopClearance - 8)",
            ".frame(width: min(320, geo.size.width * 0.36), alignment: .leading)",
            "maxHeight: max(200, usableHeight * 0.5)",
            ".padding(.horizontal, isCompact ? SpotiglassDesign.spacingS : 6)",
        ]
        for line in flagged {
            XCTAssertFalse(Self.looseNumbers(in: line).isEmpty, "not flagged: \(line)")
        }
        let allowed = [
            "VStack(spacing: 0) {",
            ".padding(SpotiglassDesign.spacingM)",
            ".frame(width: 0, height: 0)",
            ".frame(height: 1)",
            ".frame(maxWidth: .infinity, alignment: .leading)",
            ".frame(width: SpotiglassDesign.Layout.cardWidth)",
            "Spacer(minLength: 0)",
            ".font(.system(size: 13))",
            ".shadow(color: .black.opacity(0.12), radius: 18, y: 10)",
            "// .padding(6) in a comment",
            ".frame(width: geo.size.width * 0.36)",
            ".frame(width: SpotiglassDesign.Layout.cardWidth * 2)",
            ".frame(maxWidth: isWide ? SpotiglassDesign.Layout.paragraphMaxWidth : .infinity)",
            "static let maxHeight: CGFloat = 14",
        ]
        for line in allowed {
            XCTAssertTrue(Self.looseNumbers(in: line).isEmpty, "wrongly flagged: \(line)")
        }
    }

    /// A preview is left out, but a view written below one is still checked.
    func testScannerChecksCodeAfterAPreview() {
        let source = """
        struct A: View { var body: some View { Text("a").padding(SpotiglassDesign.spacingM) } }
        #Preview {
            A()
                .frame(width: 400)
                .padding(20)
        }
        struct B: View { var body: some View { Text("b").padding(6) } }
        """
        let kept = Self.linesOutsidePreviews(source).map(\.1)
        XCTAssertEqual(kept.flatMap { Self.looseNumbers(in: $0) }, ["6"])
    }

    // MARK: - Scanner

    private static let number = #"-?\d+(?:\.\d+)?"#

    /// One expression per place a layout number can hide in SwiftUI code.
    private static let patterns: [NSRegularExpression] = [
        #"\bspacing:\s*(\#(number))"#,
        #"\.padding\(\s*(\#(number))"#,
        #"\.padding\([^()]*?,\s*(\#(number))"#,
        #"\b(?:width|height|minWidth|maxWidth|minHeight|maxHeight|idealWidth|idealHeight):\s*(\#(number))"#,
        #"\.offset\([^)]*?\b[xy]:\s*(\#(number))"#,
        #"EdgeInsets\([^)]*?\b(?:top|leading|bottom|trailing):\s*(\#(number))"#,
        #"\bminLength:\s*(\#(number))"#,
        #"\.spacing\s*=\s*(\#(number))"#,
        #"\b\w+(?:Padding|Spacing):\s*(\#(number))"#,
        #"(?:Artwork\w*|Logo)\([^)]*?\bsize:\s*(\#(number))"#,
        #"\.(?:adaptive|fixed|flexible)\((?:minimum:\s*)?(\#(number))"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// Zero (no gap) and one (a hairline) are not spacing decisions.
    private static let allowedValues: Set<Double> = [0, 1]

    static func looseNumbers(in line: String) -> [String] {
        let code = line.components(separatedBy: "//").first ?? line
        let range = NSRange(code.startIndex..., in: code)
        // Keyed by where the digits start, so a number two patterns find counts once.
        var hits: [Int: String] = [:]
        for pattern in patterns {
            for match in pattern.matches(in: code, range: range) {
                guard let valueRange = Range(match.range(at: 1), in: code),
                      let value = Double(code[valueRange]),
                      !allowedValues.contains(abs(value))
                else { continue }
                let digits = code[valueRange].drop { $0 == "-" }
                hits[code.distance(from: code.startIndex, to: digits.startIndex)] = String(code[valueRange])
            }
        }
        for argument in layoutArguments(in: code) {
            for match in literal.matches(in: code, range: NSRange(argument, in: code)) {
                guard let valueRange = Range(match.range, in: code),
                      let value = Double(code[valueRange]),
                      !allowedValues.contains(value),
                      !isScaleFactor(valueRange, in: code)
                else { continue }
                let offset = code.distance(from: code.startIndex, to: valueRange.lowerBound)
                if hits[offset] == nil { hits[offset] = String(code[valueRange]) }
            }
        }
        return hits.sorted { $0.key < $1.key }.map(\.value)
    }

    /// A bare number that isn't part of a name or a member access.
    private static let literal = try! NSRegularExpression(pattern: #"(?<![\w.])\d+(?:\.\d+)?(?![\w.])"#)

    /// Labels whose whole argument is a layout size, so a number anywhere in it
    /// (`min(320, width * 0.36)`, `isWide ? 420 : .infinity`, `top - 8`) is loose.
    private static let layoutLabel = try! NSRegularExpression(
        pattern: #"(?<!let )(?<!var )\b(?:spacing|width|height|minWidth|maxWidth|minHeight|maxHeight|idealWidth|idealHeight|minLength)\s*:"#
    )

    /// The argument expressions of `.padding(...)` and of every `layoutLabel`,
    /// each running to the next comma or closing bracket at its own depth.
    private static func layoutArguments(in code: String) -> [Range<String.Index>] {
        var starts: [String.Index] = []
        for match in layoutLabel.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            if let range = Range(match.range, in: code) { starts.append(range.upperBound) }
        }
        var searchFrom = code.startIndex
        while let padding = code.range(of: ".padding(", range: searchFrom..<code.endIndex) {
            starts.append(padding.upperBound)
            searchFrom = padding.upperBound
        }
        return starts.map { start in
            var depth = 0
            var index = start
            // `.padding(` owns everything up to its own closing bracket, commas included.
            let isPadding = code[..<start].hasSuffix(".padding(")
            while index < code.endIndex {
                let character = code[index]
                if "([".contains(character) {
                    depth += 1
                } else if ")]".contains(character) {
                    if depth == 0 { break }
                    depth -= 1
                } else if character == ",", depth == 0, !isPadding {
                    break
                }
                index = code.index(after: index)
            }
            return start..<index
        }
    }

    /// `width * 0.36` or `cardWidth * 2` scales a shared value instead of being one.
    private static func isScaleFactor(_ range: Range<String.Index>, in code: String) -> Bool {
        let before = code[..<range.lowerBound].last { !$0.isWhitespace }
        let after = code[range.upperBound...].first { !$0.isWhitespace }
        return before == "*" || before == "/" || after == "*" || after == "/"
    }

    /// `file:line: code` for every loose layout number in the app's sources,
    /// leaving out the design system itself and `#Preview` blocks.
    static func looseLayoutNumbers() throws -> [String] {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryURL.appendingPathComponent("Spotiglass", isDirectory: true)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sourceURL, includingPropertiesForKeys: nil))
        var findings: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard url.lastPathComponent != "SpotiglassDesignSystem.swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text.contains("import SwiftUI") else { continue }
            let relative = url.path.replacingOccurrences(of: repositoryURL.path + "/", with: "")
            for (index, line) in linesOutsidePreviews(text) {
                if !looseNumbers(in: line).isEmpty {
                    findings.append("\(relative):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        return findings.sorted()
    }

    /// The source's lines with their index, leaving out each `#Preview { ... }`
    /// block. Code after a preview (ScrubberView has a type below its preview)
    /// is still scanned.
    static func linesOutsidePreviews(_ text: String) -> [(Int, String)] {
        var kept: [(Int, String)] = []
        var previewDepth: Int?
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            if previewDepth == nil, line.hasPrefix("#Preview") { previewDepth = 0 }
            guard let depth = previewDepth else {
                kept.append((index, line))
                continue
            }
            let opened = line.filter { $0 == "{" }.count
            let closed = line.filter { $0 == "}" }.count
            let newDepth = depth + opened - closed
            previewDepth = (opened > 0 || depth > 0) && newDepth <= 0 ? nil : newDepth
        }
        return kept
    }
}
