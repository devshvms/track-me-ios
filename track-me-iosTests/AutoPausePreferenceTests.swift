import XCTest
@testable import track_me_ios
final class AutoPausePreferenceTests: XCTestCase {
    func testMissingDefaultsToEnabled() {
        XCTAssertTrue(AutoPausePreference.isEnabled(cleanDefaults(named: #function)))
    }

    func testExplicitFalseDisablesUnlockedOverride() {
        let defaults = cleanDefaults(named: #function)
        defaults.set(false, forKey: "intelligentAutoPause")
        XCTAssertFalse(
            AutoPausePreference.isEnabled(defaults, debugModeEnabled: true)
        )
    }

    func testExplicitTrueEnablesDebugOverride() {
        let defaults = cleanDefaults(named: #function)
        defaults.set(true, forKey: "intelligentAutoPause")
        XCTAssertTrue(
            AutoPausePreference.isEnabled(defaults, debugModeEnabled: true)
        )
    }

    func testLockedPolicyIgnoresStaleDisabledOverride() {
        let defaults = cleanDefaults(named: #function)
        defaults.set(false, forKey: "intelligentAutoPause")

        XCTAssertTrue(
            AutoPausePreference.isEnabled(defaults, debugModeEnabled: false)
        )
    }

    func testUnlockedPolicyHonorsExplicitOverrideAndDefaultsOn() {
        let defaults = cleanDefaults(named: #function)
        XCTAssertTrue(
            AutoPausePreference.isEnabled(defaults, debugModeEnabled: true)
        )

        defaults.set(false, forKey: "intelligentAutoPause")
        XCTAssertFalse(
            AutoPausePreference.isEnabled(defaults, debugModeEnabled: true)
        )
    }

    private func cleanDefaults(named suiteName: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
