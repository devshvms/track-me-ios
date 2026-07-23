import XCTest
@testable import track_me_ios

@MainActor
final class AppUpdateLogicTests: XCTestCase {

    func testIsNewerBuild() {
        // Build number strictly greater
        XCTAssertTrue(AppUpdateManager.isNewerBuild(latestBuild: 42, currentBuild: 41, latestName: "1.2.0", currentName: "1.2.0"))

        // Build number equal, semver strictly greater
        XCTAssertTrue(AppUpdateManager.isNewerBuild(latestBuild: 41, currentBuild: 41, latestName: "1.3.0", currentName: "1.2.0"))

        // Build number equal, semver equal
        XCTAssertFalse(AppUpdateManager.isNewerBuild(latestBuild: 41, currentBuild: 41, latestName: "1.2.0", currentName: "1.2.0"))

        // Build number strictly lesser
        XCTAssertFalse(AppUpdateManager.isNewerBuild(latestBuild: 40, currentBuild: 41, latestName: "1.3.0", currentName: "1.2.0"))

        // Semver tiebreak checks
        XCTAssertTrue(AppUpdateManager.isNewerBuild(latestBuild: 41, currentBuild: 41, latestName: "1.10.0", currentName: "1.9.9"))
    }

    func testShouldPrompt() {
        let now = Date()
        let past25h = now.addingTimeInterval(-25 * 60 * 60)
        let past1h = now.addingTimeInterval(-1 * 60 * 60)

        // Force always prompts
        XCTAssertTrue(AppUpdateManager.shouldPrompt(latestBuild: 42, dismissedBuild: 42, dismissedAt: past1h, now: now, forceCheck: false, isForce: true))
        XCTAssertTrue(AppUpdateManager.shouldPrompt(latestBuild: 42, dismissedBuild: 42, dismissedAt: past1h, now: now, forceCheck: true, isForce: false))

        // Same-build within 24h == false
        XCTAssertFalse(AppUpdateManager.shouldPrompt(latestBuild: 42, dismissedBuild: 42, dismissedAt: past1h, now: now, forceCheck: false, isForce: false))

        // Same-build after 24h == true
        XCTAssertTrue(AppUpdateManager.shouldPrompt(latestBuild: 42, dismissedBuild: 42, dismissedAt: past25h, now: now, forceCheck: false, isForce: false))

        // Newer-build always true (even if within 24h of older dismissal)
        XCTAssertTrue(AppUpdateManager.shouldPrompt(latestBuild: 43, dismissedBuild: 42, dismissedAt: past1h, now: now, forceCheck: false, isForce: false))

        // Never dismissed == true
        XCTAssertTrue(AppUpdateManager.shouldPrompt(latestBuild: 42, dismissedBuild: nil, dismissedAt: nil, now: now, forceCheck: false, isForce: false))
    }

    func testPlaceholderURLDisabled() {
        let disabledURL = URL(string: "https://apps.apple.com/app/idXXXXXXXXXX")!
        let enabledURL = URL(string: "https://apps.apple.com/app/id1234567890")!

        XCTAssertTrue(AppUpdateManager.isPlaceholderURLDisabled(url: disabledURL))
        XCTAssertFalse(AppUpdateManager.isPlaceholderURLDisabled(url: enabledURL))
    }
}
