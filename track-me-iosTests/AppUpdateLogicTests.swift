import XCTest
@testable import track_me_ios

@MainActor
final class AppUpdateLogicTests: XCTestCase {

    func testVersionComparison() {
        XCTAssertTrue(AppUpdateManager.isNewerVersion(remote: "1.3.0", current: "1.2.0"))
        XCTAssertTrue(AppUpdateManager.isNewerVersion(remote: "1.10.0", current: "1.9.9"))
        XCTAssertTrue(AppUpdateManager.isNewerVersion(remote: "2.0", current: "1.9.9"))
        XCTAssertFalse(AppUpdateManager.isNewerVersion(remote: "1.2.0", current: "1.2.0"))
        XCTAssertFalse(AppUpdateManager.isNewerVersion(remote: "1.1.9", current: "1.2.0"))
    }

    func testShouldPrompt() {
        let now = Date()
        let past25h = now.addingTimeInterval(-25 * 60 * 60)
        let past1h = now.addingTimeInterval(-1 * 60 * 60)

        XCTAssertTrue(AppUpdateManager.shouldPrompt(latestVersion: "1.7.1", dismissedVersion: "1.7.1", dismissedAt: past1h, now: now, forceCheck: true))

        // Same-build within 24h == false
        XCTAssertFalse(AppUpdateManager.shouldPrompt(latestVersion: "1.7.1", dismissedVersion: "1.7.1", dismissedAt: past1h, now: now, forceCheck: false))

        // Same-build after 24h == true
        XCTAssertTrue(AppUpdateManager.shouldPrompt(latestVersion: "1.7.1", dismissedVersion: "1.7.1", dismissedAt: past25h, now: now, forceCheck: false))

        // Newer-build always true (even if within 24h of older dismissal)
        XCTAssertTrue(AppUpdateManager.shouldPrompt(latestVersion: "1.7.2", dismissedVersion: "1.7.1", dismissedAt: past1h, now: now, forceCheck: false))

        // Never dismissed == true
        XCTAssertTrue(AppUpdateManager.shouldPrompt(latestVersion: "1.7.1", dismissedVersion: nil, dismissedAt: nil, now: now, forceCheck: false))
    }

    func testLookupURLUsesBundleAndStorefront() throws {
        let url = try XCTUnwrap(AppUpdateManager.lookupURL(bundleIdentifier: "in.shvms.track-me-ios", countryCode: "de"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "itunes.apple.com")
        XCTAssertEqual(components.queryItems?.first { $0.name == "bundleId" }?.value, "in.shvms.track-me-ios")
        XCTAssertEqual(components.queryItems?.first { $0.name == "country" }?.value, "DE")
    }

    func testLookupEligibilitySkipsNonStoreBuilds() {
        XCTAssertFalse(AppUpdateManager.shouldPerformLookup(isDebugBuild: true, isSimulator: false, appStoreEnvironment: .production))
        XCTAssertFalse(AppUpdateManager.shouldPerformLookup(isDebugBuild: false, isSimulator: true, appStoreEnvironment: .production))
        XCTAssertFalse(AppUpdateManager.shouldPerformLookup(isDebugBuild: false, isSimulator: false, appStoreEnvironment: .sandbox))
        XCTAssertFalse(AppUpdateManager.shouldPerformLookup(isDebugBuild: false, isSimulator: false, appStoreEnvironment: .xcode))
        XCTAssertFalse(AppUpdateManager.shouldPerformLookup(isDebugBuild: false, isSimulator: false, appStoreEnvironment: nil))
        XCTAssertTrue(AppUpdateManager.shouldPerformLookup(isDebugBuild: false, isSimulator: false, appStoreEnvironment: .production))
    }

    func testLookupResponseUsesAppStoreVersionAndNotes() throws {
        let data = Data(#"{"resultCount":1,"results":[{"version":"1.7.1","releaseNotes":"Store notes","trackViewUrl":"https://apps.apple.com/app/id123"}]}"#.utf8)
        let response = try JSONDecoder().decode(AppStoreLookupResponse.self, from: data)
        XCTAssertEqual(response.results.first?.version, "1.7.1")
        XCTAssertEqual(response.results.first?.releaseNotes, "Store notes")
    }
}
