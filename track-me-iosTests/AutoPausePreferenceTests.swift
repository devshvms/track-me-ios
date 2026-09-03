import XCTest
@testable import track_me_ios
final class AutoPausePreferenceTests: XCTestCase {
    func testMissingDefaultsToEnabled() {
        XCTAssertTrue(AutoPausePreference.isEnabled(cleanDefaults(named: #function)))
    }

    func testExplicitFalseDisablesDebugOverride() {
        let defaults = cleanDefaults(named: #function)
        defaults.set(false, forKey: "intelligentAutoPause")
        XCTAssertFalse(
            AutoPausePreference.isEnabled(defaults, debugOverridesAvailable: true)
        )
    }

    func testExplicitTrueEnablesDebugOverride() {
        let defaults = cleanDefaults(named: #function)
        defaults.set(true, forKey: "intelligentAutoPause")
        XCTAssertTrue(
            AutoPausePreference.isEnabled(defaults, debugOverridesAvailable: true)
        )
    }

    func testReleasePolicyIgnoresStaleDisabledOverride() {
        let defaults = cleanDefaults(named: #function)
        defaults.set(false, forKey: "intelligentAutoPause")

        XCTAssertTrue(
            AutoPausePreference.isEnabled(defaults, debugOverridesAvailable: false)
        )
    }

    func testDebugPolicyHonorsExplicitOverrideAndDefaultsOn() {
        let defaults = cleanDefaults(named: #function)
        XCTAssertTrue(
            AutoPausePreference.isEnabled(defaults, debugOverridesAvailable: true)
        )

        defaults.set(false, forKey: "intelligentAutoPause")
        XCTAssertFalse(
            AutoPausePreference.isEnabled(defaults, debugOverridesAvailable: true)
        )
    }

    private func cleanDefaults(named suiteName: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
