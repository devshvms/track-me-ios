import XCTest
@testable import track_me_ios

final class LiveShareSliderAndSetupTests: XCTestCase {

    private let prefKey = LiveShareFrequencySliderPolicy.prefKey
    private var savedOriginalPref: Any?

    override func setUp() {
        super.setUp()
        savedOriginalPref = UserDefaults.standard.object(forKey: prefKey)
    }

    override func tearDown() {
        if let savedOriginalPref {
            UserDefaults.standard.set(savedOriginalPref, forKey: prefKey)
        } else {
            UserDefaults.standard.removeObject(forKey: prefKey)
        }
        super.tearDown()
    }

    func testSliderPolicyMatchesSixStepBatteryToFrequencyOrder() {
        XCTAssertEqual(LiveShareFrequencySliderPolicy.stepsSeconds, [300, 60, 30, 15, 10, 5])
        XCTAssertEqual(LiveShareFrequencySliderPolicy.stepCount, 6)
        XCTAssertEqual(LiveShareFrequencySliderPolicy.maxIndex, 5)
        XCTAssertEqual(LiveShareFrequencySliderPolicy.defaultSeconds, 15)
        XCTAssertEqual(LiveShareFrequencySliderPolicy.defaultIndex, 3)
    }

    func testSliderRoundTripsAllSixPositionsAndSeededDefaultPreference() {
        // Seeded default 15s preference resolves cleanly to index 3.
        UserDefaults.standard.set(15, forKey: prefKey)
        let seeded = UserDefaults.standard.integer(forKey: prefKey)
        XCTAssertEqual(LiveShareFrequencySliderPolicy.index(forSeconds: seeded), 3)

        for (index, seconds) in LiveShareFrequencySliderPolicy.stepsSeconds.enumerated() {
            XCTAssertEqual(LiveShareFrequencySliderPolicy.index(forSeconds: seconds), index)
            XCTAssertEqual(LiveShareFrequencySliderPolicy.seconds(forIndex: index), seconds)
            XCTAssertEqual(LiveShareFrequencySliderPolicy.seconds(forSliderValue: Double(index)), seconds)

            // Verify persistence round-trip through the existing UserDefaults key read by LiveSharingManager.
            UserDefaults.standard.set(seconds, forKey: prefKey)
            let reloaded = UserDefaults.standard.integer(forKey: prefKey)
            XCTAssertEqual(reloaded, seconds)
            XCTAssertEqual(LiveShareFrequencySliderPolicy.index(forSeconds: reloaded), index)
        }
    }

    func testSliderFallbacksAndClamping() {
        XCTAssertEqual(LiveShareFrequencySliderPolicy.index(forSeconds: 0), 3)
        XCTAssertEqual(LiveShareFrequencySliderPolicy.index(forSeconds: -10), 3)
        XCTAssertEqual(LiveShareFrequencySliderPolicy.seconds(forSliderValue: .nan), 15)
        XCTAssertEqual(LiveShareFrequencySliderPolicy.seconds(forSliderValue: .infinity), 15)
        XCTAssertEqual(LiveShareFrequencySliderPolicy.seconds(forSliderValue: -3.0), 300)
        XCTAssertEqual(LiveShareFrequencySliderPolicy.seconds(forSliderValue: 42.0), 5)

        // Legacy non-standard values snap to nearest step.
        XCTAssertEqual(LiveShareFrequencySliderPolicy.index(forSeconds: 4), 5)
        XCTAssertEqual(LiveShareFrequencySliderPolicy.index(forSeconds: 11), 4)
        XCTAssertEqual(LiveShareFrequencySliderPolicy.index(forSeconds: 16), 3)
        XCTAssertEqual(LiveShareFrequencySliderPolicy.index(forSeconds: 25), 2)
        XCTAssertEqual(LiveShareFrequencySliderPolicy.index(forSeconds: 90), 1)
        XCTAssertEqual(LiveShareFrequencySliderPolicy.index(forSeconds: 600), 0)
    }

    func testIntervalAndDurationShortFormatters() {
        XCTAssertFalse(SettingsView.formatLiveShareInterval(300).contains("%@"))
        XCTAssertFalse(SettingsView.formatLiveShareInterval(60).contains("%@"))
        XCTAssertFalse(SettingsView.formatLiveShareInterval(15).contains("%@"))
        XCTAssertFalse(SettingsView.formatLiveShareInterval(5).contains("%@"))

        XCTAssertEqual(LiveShareSetupSheet.durationOptions, [30, 60, 120, 1440])
        for minutes in LiveShareSetupSheet.durationOptions {
            let formatted = LiveShareSetupSheet.formatDuration(minutes)
            XCTAssertFalse(formatted.isEmpty)
            XCTAssertFalse(formatted.contains("%@"))
        }
    }

    func testAllTwelveTask377And378KeysExistAcrossAllSevenLocalesInCatalog() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL.deletingLastPathComponent().deletingLastPathComponent()
        let catalogURL = repoRoot.appendingPathComponent("track-me-ios/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])

        let requiredKeys = [
            "Live location updates",
            "Less battery use",
            "More frequent updates",
            "Shorter intervals can use more battery.",
            "%@ sec",
            "%@ min",
            "%@ hr",
            "Sharing time limit · %@",
            "Change",
            "Sharing stops automatically at this limit. You can stop it sooner.",
            "Ending your ride also stops sharing.",
            "Anyone with the link can view your live location. Opening this page shares nothing.",
        ]
        let locales = ["en", "de", "es", "fr", "hi", "ja", "zh-Hans"]

        for key in requiredKeys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "Missing xcstrings key: \(key)")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], "Missing localizations for: \(key)")
            for locale in locales {
                let loc = try XCTUnwrap(localizations[locale] as? [String: Any], "Missing locale \(locale) for: \(key)")
                let unit = try XCTUnwrap(loc["stringUnit"] as? [String: Any], "Missing stringUnit for \(key) [\(locale)]")
                let value = try XCTUnwrap(unit["value"] as? String)
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty value for \(key) [\(locale)]")
            }
        }

        // Guard against battery percentage claims in the battery note.
        let batteryEntry = try XCTUnwrap(strings["Shorter intervals can use more battery."] as? [String: Any])
        let batteryLocs = try XCTUnwrap(batteryEntry["localizations"] as? [String: Any])
        for locale in locales {
            let value = (((batteryLocs[locale] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String) ?? ""
            XCTAssertFalse(value.contains("%"), "Battery note in \(locale) must not contain percentages")
        }
    }
}
