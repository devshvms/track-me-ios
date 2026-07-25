import XCTest
@testable import track_me_ios
final class AutoPausePreferenceTests: XCTestCase {
    func testMissingDefaultsToEnabled() { XCTAssertTrue(AutoPausePreference.isEnabled(UserDefaults(suiteName: #function)!)) }
    func testExplicitFalseDisables() { let d = UserDefaults(suiteName: #function)!; d.set(false, forKey: "intelligentAutoPause"); XCTAssertFalse(AutoPausePreference.isEnabled(d)) }
    func testExplicitTrueEnables() { let d = UserDefaults(suiteName: #function)!; d.set(true, forKey: "intelligentAutoPause"); XCTAssertTrue(AutoPausePreference.isEnabled(d)) }
}
