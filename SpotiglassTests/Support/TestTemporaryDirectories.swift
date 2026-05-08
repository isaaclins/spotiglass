import Foundation

func spotiglassTestsTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("SpotiglassTests-\(UUID().uuidString)", isDirectory: true)
}
