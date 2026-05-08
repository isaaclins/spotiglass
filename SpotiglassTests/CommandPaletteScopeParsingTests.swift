import XCTest
@testable import Spotiglass

final class CommandPaletteScopeParsingTests: XCTestCase {
    func testScopeParseEmptyDefaultsToSongs() {
        let result = CommandPaletteScope.parse("")
        XCTAssertEqual(result.scope, .songs)
        XCTAssertEqual(result.query, "")
    }

    func testScopeParsePlainQueryDefaultsToSongs() {
        let result = CommandPaletteScope.parse("midnight")
        XCTAssertEqual(result.scope, .songs)
        XCTAssertEqual(result.query, "midnight")
    }

    func testScopeParseGreaterThanPrefixYieldsCommandsScope() {
        let bare = CommandPaletteScope.parse(">")
        XCTAssertEqual(bare.scope, .commands)
        XCTAssertEqual(bare.query, "")

        let withQuery = CommandPaletteScope.parse(">refresh")
        XCTAssertEqual(withQuery.scope, .commands)
        XCTAssertEqual(withQuery.query, "refresh")
    }

    func testScopeParseAtPrefixIsStillSongsScopeQueryUnchanged() {
        let bare = CommandPaletteScope.parse("@")
        XCTAssertEqual(bare.scope, .songs)
        XCTAssertEqual(bare.query, "@")

        let withQuery = CommandPaletteScope.parse("@malcolm")
        XCTAssertEqual(withQuery.scope, .songs)
        XCTAssertEqual(withQuery.query, "@malcolm")
    }
}
