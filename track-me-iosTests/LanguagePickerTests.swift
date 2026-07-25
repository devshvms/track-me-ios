import XCTest
@testable import track_me_ios

/// Guards the in-app Settings language picker (prompt 34, TASK-058).
///
/// The functional fix for the "Chinese is shipped but unreachable" gap is a single
/// data entry in `SettingsView.languages`. These are pure assertions on that static
/// set — they intentionally do NOT touch the string catalog / app bundle (that
/// resolution is exercised by the manual build-and-switch-to-中文 gate in the prompt,
/// not reliably reachable from the test bundle). Their job is to stop a future edit
/// from silently dropping Chinese again or reintroducing the wrong identifier.
final class LanguagePickerTests: XCTestCase {

    private var codes: [String] { SettingsView.languages.map(\.0) }

    func testOffersSimplifiedChinese() {
        XCTAssertTrue(codes.contains("zh-Hans"),
                      "Settings picker must offer Simplified Chinese as 'zh-Hans'")
    }

    func testChineseUsesZhHansNotBareZh() {
        // "zh" would rely on fuzzy fallback; the catalog key is exactly "zh-Hans".
        XCTAssertFalse(codes.contains("zh"),
                       "Use 'zh-Hans' (matches the Localizable.xcstrings key), not Android's bare 'zh'")
    }

    func testChineseLabelIsZhongwen() {
        let chinese = SettingsView.languages.first { $0.0 == "zh-Hans" }
        XCTAssertEqual(chinese?.1, "中文",
                       "Simplified-only ships, so the label is '中文' with no 简体/繁體 disambiguation")
    }

    func testNoTraditionalChineseOffered() {
        // The catalog has no zh-Hant localization; offering it would resolve to English.
        XCTAssertFalse(codes.contains("zh-Hant"),
                       "Do not offer Traditional Chinese — it is not in the string catalog")
    }

    func testAllSevenLanguagesPresentAndUnique() {
        let expected = ["en", "es", "fr", "de", "hi", "ja", "zh-Hans"]
        XCTAssertEqual(codes, expected, "Picker must offer exactly the 7 shipped languages, in order")
        XCTAssertEqual(Set(codes).count, codes.count, "Language codes must be unique")
    }
}
