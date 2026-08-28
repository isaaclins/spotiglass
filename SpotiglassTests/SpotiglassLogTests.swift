import XCTest
@testable import Spotiglass

final class SpotiglassLogTests: XCTestCase {
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
}
