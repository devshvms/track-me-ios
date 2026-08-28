import XCTest
@testable import track_me_ios

/// Base class for tests that assert on English copy.
///
/// TASK-241 exposed why this is needed. `LocalizationHelper.localized` used to ignore the in-app
/// language entirely and resolve in the *device* language, so these tests passed on an
/// English-language simulator no matter what `appLanguage` held — they were green **because of the
/// defect**, which is exactly why none of them caught it. The moment the helper started honouring
/// the setting, nine of them failed against a simulator left in French.
///
/// Asserting on copy at all is a choice worth keeping honest: these tests check that the right
/// *message* is selected, so they need one known language, not whichever the machine happens to be
/// in. Pinning it here makes that a stated precondition instead of an accident of the environment.
///
/// The original value is restored, because the test bundle runs inside the host app and shares its
/// UserDefaults — leaving it pinned would silently change the language of the installed app.
class EnglishCopyTestCase: XCTestCase {
    private var previousLanguage: String?

    override func setUp() {
        super.setUp()
        previousLanguage = UserDefaults.standard.string(forKey: "appLanguage")
        UserDefaults.standard.set("en", forKey: "appLanguage")
    }

    override func tearDown() {
        if let previousLanguage {
            UserDefaults.standard.set(previousLanguage, forKey: "appLanguage")
        } else {
            UserDefaults.standard.removeObject(forKey: "appLanguage")
        }
        super.tearDown()
    }
}
