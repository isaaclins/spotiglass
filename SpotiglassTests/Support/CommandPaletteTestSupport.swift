import Foundation
import XCTest

extension XCTestCase {
    func makeCommandPaletteTestsTempSettingsURL() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
        }
        return dir.appendingPathComponent("settings.json", isDirectory: false)
    }
}
