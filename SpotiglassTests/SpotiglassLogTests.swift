import XCTest
@testable import Spotiglass

final class SpotiglassLogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpotiglassLogTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory) // The folder may never have been created.
    }

    func testInfoAndErrorOnAllCategories() {
        SpotiglassLog.debug(SpotiglassLog.browsing, "browsing debug")
        SpotiglassLog.info(SpotiglassLog.auth, "auth info")
        SpotiglassLog.error(SpotiglassLog.auth, "auth error")
        SpotiglassLog.info(SpotiglassLog.api, "api info")
        SpotiglassLog.error(SpotiglassLog.api, "api error")
        SpotiglassLog.info(SpotiglassLog.playback, "playback info")
        SpotiglassLog.error(SpotiglassLog.playback, "playback error")
        SpotiglassLog.info(SpotiglassLog.browsing, "browsing info")
        SpotiglassLog.error(SpotiglassLog.browsing, "browsing error")
        SpotiglassLog.info(SpotiglassLog.pinning, "pinning info")
        SpotiglassLog.error(SpotiglassLog.pinning, "pinning error")
        SpotiglassLog.info(SpotiglassLog.settings, "settings info")
        SpotiglassLog.error(SpotiglassLog.settings, "settings error")
        SpotiglassLog.info(SpotiglassLog.persistence, "persistence info")
        SpotiglassLog.error(SpotiglassLog.persistence, "persistence error")
    }

    /// `make test` used to rotate the user's real log away and fill it with test noise (#602).
    func testTheTestHostLogsOutsideTheRealLogsFolder() throws {
        let realLogs = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ).appendingPathComponent("\(AppMetadata.storageDirectoryName)/Logs", isDirectory: true)
        XCTAssertTrue(AppMetadata.isRunningUnitTests)
        let url = try XCTUnwrap(SpotiglassLog.logFileURL, "The test host must still have a log file to write to.")
        XCTAssertFalse(
            url.standardizedFileURL.path.hasPrefix(realLogs.standardizedFileURL.path),
            "\(url.path) is in the real Logs folder"
        )
    }

    func testFoldersOfFinishedTestRunsAreRemovedAndRunningOnesKept() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["SpotiglassTestLogs-111", "SpotiglassTestLogs-222", "SomethingElse-111"] {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(name), withIntermediateDirectories: true
            )
        }

        SpotiglassLog.removeFinishedTestLogFolders(in: directory, isRunning: { $0 == 222 })

        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(left, ["SomethingElse-111", "SpotiglassTestLogs-222"])
    }

    func testAFullFileMovesToTheEarlierFileAndTheNewestLinesStay() throws {
        let sink = FileLogSink(directory: { self.directory }, maxBytes: 400)
        sink.boot()
        for index in 0..<40 {
            sink.write(level: "INFO", category: "api", message: "line \(index)")
        }
        sink.flush()

        let current = try String(contentsOf: directory.appendingPathComponent(FileLogSink.currentFileName), encoding: .utf8)
        let earlier = try String(contentsOf: directory.appendingPathComponent(FileLogSink.earlierFileName), encoding: .utf8)
        XCTAssertTrue(current.contains("line 39"), "The newest line must be in the current file.")
        XCTAssertTrue(current.contains("earlier lines in \(FileLogSink.earlierFileName)"))
        for file in [FileLogSink.currentFileName, FileLogSink.earlierFileName] {
            let size = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(file).path)[.size] as? UInt64
            )
            XCTAssertLessThanOrEqual(size, 400, "\(file) grew past the cap")
        }
        XCTAssertFalse(earlier.isEmpty)
    }

    func testANewLaunchKeepsThePreviousSessionsLines() throws {
        let first = FileLogSink(directory: { self.directory })
        first.boot()
        first.write(level: "ERROR", category: "auth", message: "first session line", synchronously: true)

        let second = FileLogSink(directory: { self.directory })
        second.boot()
        second.flush()

        let previous = try String(contentsOf: directory.appendingPathComponent(FileLogSink.previousFileName), encoding: .utf8)
        XCTAssertTrue(previous.contains("first session line"))
        let current = try String(contentsOf: directory.appendingPathComponent(FileLogSink.currentFileName), encoding: .utf8)
        XCTAssertFalse(current.contains("first session line"))
    }

    /// A failed rotation used to fall through to `createFile`, which emptied the very file it
    /// meant to keep (#602).
    func testAFailedRotationKeepsThePreviousSessionsLines() throws {
        let first = FileLogSink(directory: { self.directory })
        first.boot()
        first.write(level: "ERROR", category: "auth", message: "evidence from the crashed session", synchronously: true)

        struct MoveRefused: Error {}
        let second = FileLogSink(directory: { self.directory }, moveItem: { _, _ in throw MoveRefused() })
        second.boot()
        second.write(level: "INFO", category: "api", message: "new session line")
        second.flush()

        let current = try String(contentsOf: directory.appendingPathComponent(FileLogSink.currentFileName), encoding: .utf8)
        XCTAssertTrue(current.contains("evidence from the crashed session"))
        XCTAssertTrue(current.contains("Could not move the previous session's log aside"))
        XCTAssertTrue(current.contains("new session line"))
    }

    /// When the session appends to the previous session's file and that file later fills up
    /// and can't be moved either, starting it over would empty the previous session's lines.
    func testAFullFileHoldingThePreviousSessionIsNeverEmptied() throws {
        let first = FileLogSink(directory: { self.directory })
        first.boot()
        first.write(level: "ERROR", category: "auth", message: "evidence from the crashed session", synchronously: true)

        struct MoveRefused: Error {}
        let second = FileLogSink(directory: { self.directory }, maxBytes: 600, moveItem: { _, _ in throw MoveRefused() })
        second.boot()
        for index in 0..<40 {
            second.write(level: "INFO", category: "api", message: "line \(index)")
        }
        second.flush()

        let current = try String(contentsOf: directory.appendingPathComponent(FileLogSink.currentFileName), encoding: .utf8)
        XCTAssertTrue(current.contains("evidence from the crashed session"))
        XCTAssertTrue(current.contains("the rest of this session is in Console only"))
        XCTAssertFalse(current.contains("line 39"), "The file must stop growing once it is full")
    }

    func testAnUnusableFolderLeavesNoFileAndDoesNotCrash() {
        struct NoFolder: Error {}
        let sink = FileLogSink(directory: { throw NoFolder() })
        sink.boot()
        sink.write(level: "ERROR", category: "auth", message: "dropped", synchronously: true)
        sink.flush()
        XCTAssertNil(sink.fileURL)
    }

    /// An error line is in the file the moment `error` returns, so a crash right after can't lose it.
    func testAnErrorLineIsInTheFileWhenTheCallReturns() throws {
        let sink = FileLogSink(directory: { self.directory })
        sink.boot()
        sink.write(level: "ERROR", category: "playback", message: "last words", synchronously: true)
        let current = try String(contentsOf: directory.appendingPathComponent(FileLogSink.currentFileName), encoding: .utf8)
        XCTAssertTrue(current.contains("last words"))
    }
}

/// Reads the app's log file for tests that check a failure reached it.
enum SpotiglassLogReader {
    static func lines(containing marker: String) throws -> [String] {
        SpotiglassLog.flush()
        let url = try XCTUnwrap(SpotiglassLog.logFileURL)
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.contains(marker) }
    }
}
