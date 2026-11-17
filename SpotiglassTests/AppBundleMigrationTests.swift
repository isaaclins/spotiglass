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
    func testRelaunchSuccessAndFailure() throws {
        for succeeds in [true, false] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("Spotiglass.app")
            try Data("payload".utf8).write(to: source)
            var registered: URL?
            var finished = false
            var messages: [String] = []
            AppBundleMigration.migrate(source: source, register: { registered = $0 }, relaunch: { url, completion in
                XCTAssertEqual(url, registered)
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
                XCTAssertTrue(completion(succeeds))
            }, finish: { url in
                XCTAssertEqual(url, registered)
                finished = true
            }, log: { messages.append($0) })
            XCTAssertEqual(finished, succeeds)
            XCTAssertEqual(FileManager.default.fileExists(atPath: source.path), !succeeds)
            XCTAssertEqual(messages.isEmpty, succeeds)
        }
    }

    /// LaunchServices normally answers within a second. If it doesn't, this copy can't keep
    /// launching from a bundle that has moved: the rename is undone, and an answer that turns up
    /// later is refused, so it neither quits this copy nor touches the bundle again.
    func testARelaunchThatDoesNotAnswerIsUndoneAndItsLateAnswerRefused() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Spotiglass.app")
        try Data("payload".utf8).write(to: source)
        var pending: ((Bool) -> Bool)?
        var finished = false
        var messages: [String] = []
        AppBundleMigration.migrate(source: source, register: { _ in }, relaunch: { _, completion in
            pending = completion
        }, finish: { _ in finished = true }, log: { messages.append($0) }, timeout: .milliseconds(50))

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Wax.app").path))
        XCTAssertEqual(messages.count, 1)
        XCTAssertFalse(try XCTUnwrap(pending)(true))
        XCTAssertFalse(finished)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(messages.count, 1)
    }

    func testMigrationFailureDoesNotRelaunch() {
        var messages: [String] = []
        AppBundleMigration.migrate(source: URL(fileURLWithPath: "/missing/Spotiglass.app"), register: { _ in XCTFail() }, relaunch: { _, _ in XCTFail() }, finish: { _ in XCTFail() }, log: { messages.append($0) })
        XCTAssertEqual(messages.count, 1)
        AppBundleMigration.migrate(source: URL(fileURLWithPath: "/Applications/Wax.app"), register: { _ in XCTFail() }, relaunch: { _, _ in XCTFail() }, finish: { _ in XCTFail() }, log: { _ in XCTFail() })
    }

}
