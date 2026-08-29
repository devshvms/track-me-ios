import XCTest
@testable import track_me_ios

/// TASK-241. The app rendered two languages at once whenever the in-app language differed from the
/// device's, because `String(localized:locale:)` selects *formatting*, not a translation table.
///
/// These assert against the bundles the app actually ships, so they fail if a translation is
/// dropped from the target as well as if the resolution logic regresses.
final class LocalizationBundleTests: XCTestCase {

    private let shipped = ["en", "es", "fr", "de", "hi", "ja", "zh-Hans"]

    func testEveryShippedLanguageResolvesToItsOwnBundle() {
        for code in shipped {
            let bundle = LocalizationHelper.bundle(forLanguage: code)
            XCTAssertNotEqual(
                bundle.bundlePath, Bundle.main.bundlePath,
                "\(code) fell back to the main bundle, which is the defect this fixes"
            )
            XCTAssertTrue(
                bundle.bundlePath.hasSuffix("\(code).lproj"),
                "\(code) resolved to \(bundle.bundlePath)"
            )
        }
    }

    func testTheSameKeyResolvesDifferentlyPerLanguage() {
        // The actual user-visible symptom: one key, two languages, and before the fix both came
        // back in whatever language the *device* was set to.
        let english = LocalizationHelper.localized("Distance", localeCode: "en")
        let french = LocalizationHelper.localized("Distance", localeCode: "fr")
        let japanese = LocalizationHelper.localized("Distance", localeCode: "ja")

        XCTAssertFalse(english.isEmpty)
        // "Distance" is spelled identically in French, so it cannot carry this assertion alone —
        // Japanese uses a different script and can.
        XCTAssertNotEqual(japanese, english, "ja must not fall through to the English table")
        XCTAssertFalse(french.isEmpty)
    }

    func testAMoreSpecificCodeDegradesToTheLanguageRatherThanToEnglish() {
        // "fr-CA" ships no table. It must land on French, not silently on the device language.
        let bundle = LocalizationHelper.bundle(forLanguage: "fr-CA")
        XCTAssertTrue(bundle.bundlePath.hasSuffix("fr.lproj"), "got \(bundle.bundlePath)")
    }

    func testABareCodeFindsAScriptedTable() {
        // Chinese ships as "zh-Hans". A bare "zh" must find it rather than fall back.
        let bundle = LocalizationHelper.bundle(forLanguage: "zh")
        XCTAssertTrue(bundle.bundlePath.hasSuffix("zh-Hans.lproj"), "got \(bundle.bundlePath)")
    }

    func testAnUnknownLanguageFallsBackRatherThanFailing() {
        // Reproduces the old behaviour for a code we do not ship: wrong language, but legible.
        let bundle = LocalizationHelper.bundle(forLanguage: "xx")
        XCTAssertEqual(bundle.bundlePath, Bundle.main.bundlePath)
        XCTAssertFalse(LocalizationHelper.localized("Distance", localeCode: "xx").isEmpty)
    }
}
