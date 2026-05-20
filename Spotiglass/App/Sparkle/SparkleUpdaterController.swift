import Foundation
import Sparkle

/// Owns Sparkle's standard updater; disabled during unit tests (test host must not check for updates).
final class SparkleUpdaterController {
    let standardController: SPUStandardUpdaterController

    init() {
        let startUpdater = !AppMetadata.isRunningUnitTests
        standardController = SPUStandardUpdaterController(
            startingUpdater: startUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var updater: SPUUpdater {
        standardController.updater
    }
}
