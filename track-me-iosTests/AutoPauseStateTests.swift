import XCTest
@testable import track_me_ios

final class AutoPauseStateTests: XCTestCase {
    func testDisabledPreferenceNeverAutoPauses() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.set(false, forKey: "intelligentAutoPause")
        XCTAssertFalse(AutoPausePreference.isEnabled(defaults, debugOverridesAvailable: true))
    }
}
