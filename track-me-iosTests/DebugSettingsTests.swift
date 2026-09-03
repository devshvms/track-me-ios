import XCTest
@testable import track_me_ios

final class DebugSettingsTests: XCTestCase {
    func testFifthConsecutiveTapUnlocksAndResetsSequence() {
        var unlock = ConsecutiveTapUnlock()

        XCTAssertFalse(unlock.registerTap(uptime: 1.0))
        XCTAssertFalse(unlock.registerTap(uptime: 1.5))
        XCTAssertFalse(unlock.registerTap(uptime: 2.0))
        XCTAssertFalse(unlock.registerTap(uptime: 2.5))
        XCTAssertTrue(unlock.registerTap(uptime: 3.0))
        XCTAssertFalse(unlock.registerTap(uptime: 3.5))
    }

    func testSlowOrNonMonotonicTapsRestartAtOne() {
        var unlock = ConsecutiveTapUnlock()

        _ = unlock.registerTap(uptime: 1.0)
        _ = unlock.registerTap(uptime: 1.5)
        XCTAssertFalse(unlock.registerTap(uptime: 3.501))
        XCTAssertEqual(unlock.tapCount, 1)
        XCTAssertFalse(unlock.registerTap(uptime: 3.0))
        XCTAssertEqual(unlock.tapCount, 1)
    }

    func testEnablePersistsLocalDebugMode() {
        let defaults = cleanDefaults(named: #function)

        DebugSettings.enable(defaults)

        XCTAssertTrue(DebugSettings.isEnabled(defaults))
    }

    func testDisablingRestoresOnlyDebugDefaults() {
        let defaults = cleanDefaults(named: #function)
        defaults.set(true, forKey: DebugSettings.modeEnabledKey)
        defaults.set(false, forKey: DebugSettings.autoPauseKey)
        defaults.set(false, forKey: DebugSettings.postProcessingKey)
        defaults.set("fr", forKey: "appLanguage")

        DebugSettings.disableAndReset(defaults)

        XCTAssertFalse(DebugSettings.isEnabled(defaults))
        XCTAssertTrue(defaults.bool(forKey: DebugSettings.autoPauseKey))
        XCTAssertTrue(defaults.bool(forKey: DebugSettings.postProcessingKey))
        XCTAssertEqual(defaults.string(forKey: "appLanguage"), "fr")
    }

    func testDebugSettingsCopyIsLocalizedInEveryShippedLanguage() {
        let keys = [
            "Debug Settings",
            "Debug mode",
            "Debug mode is enabled",
            "Diagnostic controls for controlled TrackMe testing",
            "Dynamically pauses moving time based on the activity speed profile.",
            "Enable debug mode (tap 5 times)",
            "GPS drift while stopped, tunnels, and urban canyons can affect distance. TrackMe filters implausible fixes while recording; a signal gap is shown as a straight line.",
            "How do I get Pro data customizations?",
            "Open Debug Settings",
            "Pro data customizations are not available yet. Debug controls are for controlled testing and can reduce tracking accuracy.",
            "Stored diagnostic preference only. iOS currently filters fixes live and has no post-ride pipeline connected to this flag.",
            "Tracking controls",
            "Turning this off restores diagnostic settings to defaults and removes this page."
        ]

        for language in ["de", "es", "fr", "hi", "ja", "zh-Hans"] {
            for key in keys {
                XCTAssertNotEqual(
                    LocalizationHelper.localized(key, localeCode: language),
                    key,
                    "\(language) fell back to English for \(key)"
                )
            }
        }
    }

    private func cleanDefaults(named suiteName: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
