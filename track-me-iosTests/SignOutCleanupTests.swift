import XCTest
@testable import track_me_ios

@MainActor
final class SignOutCleanupTests: XCTestCase {
    func testActiveShareRequiresCleanup() {
        XCTAssertEqual(SignOutCleanup.plan(liveShareActive: true), .endLiveShare)
    }
    func testInactiveShareRequiresNoCleanup() {
        XCTAssertEqual(SignOutCleanup.plan(liveShareActive: false), .none)
    }
}
