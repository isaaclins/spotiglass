import XCTest
@testable import Spotiglass

final class AppBundleMigrationTests: XCTestCase {
    func testMovePreservesIdentityAndBookmark() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Spotiglass.app")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("signed payload".utf8).write(to: source.appendingPathComponent("payload"))
        let bookmark = try source.bookmarkData(options: .minimalBookmark)
        let id = try source.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject
        let destination = try XCTUnwrap(AppBundleMigration.moveLegacyBundle(at: source))
        XCTAssertEqual(destination.lastPathComponent, "Wax.app")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try destination.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject, id)
        var stale = false
        let resolved = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
        XCTAssertEqual(resolved.standardizedFileURL, destination.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("payload")), Data("signed payload".utf8))
        XCTAssertNil(try AppBundleMigration.moveLegacyBundle(at: destination))
    }

    func testExistingDestinationIsNeverOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Spotiglass.app")
        let destination = root.appendingPathComponent("Wax.app")
        try Data("old".utf8).write(to: source)
        try Data("other install".utf8).write(to: destination)
        XCTAssertThrowsError(try AppBundleMigration.moveLegacyBundle(at: source))
        XCTAssertEqual(try Data(contentsOf: source), Data("old".utf8))
        XCTAssertEqual(try Data(contentsOf: destination), Data("other install".utf8))
    }

    func testCustomNamesAreRespected() throws {
        XCTAssertNil(try AppBundleMigration.moveLegacyBundle(at: URL(fileURLWithPath: "/Applications/My Player.app")))
        XCTAssertNil(try AppBundleMigration.moveLegacyBundle(at: URL(fileURLWithPath: "/private/AppTranslocation/test/Spotiglass.app")))
    }
}
