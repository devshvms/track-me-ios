import XCTest
@testable import track_me_ios

/// Unit tests for the pure B4 `ReviewPromptPolicy` (iOS). Mirrors the Android policy test.
final class ReviewPromptPolicyTests: XCTestCase {

    private let now: Int64 = 1_700_000_000_000
    private let day: Int64 = 24 * 60 * 60 * 1000

    func testEligibleWhenEnoughRidesNeverPromptedNewVersion() {
        XCTAssertTrue(ReviewPromptPolicy.isEligible(
            goodRideCount: 3, lastPromptedAtMillis: 0, lastPromptedVersion: nil,
            currentVersion: "1.6.0", nowMillis: now))
    }

    func testNotEligibleBelowRideThreshold() {
        XCTAssertFalse(ReviewPromptPolicy.isEligible(
            goodRideCount: 2, lastPromptedAtMillis: 0, lastPromptedVersion: nil,
            currentVersion: "1.6.0", nowMillis: now))
    }

    func testNotEligibleSameVersionAlreadyAsked() {
        XCTAssertFalse(ReviewPromptPolicy.isEligible(
            goodRideCount: 10, lastPromptedAtMillis: now - 400 * day, lastPromptedVersion: "1.6.0",
            currentVersion: "1.6.0", nowMillis: now))
    }

    func testNotEligibleWithinCooldown() {
        XCTAssertFalse(ReviewPromptPolicy.isEligible(
            goodRideCount: 10, lastPromptedAtMillis: now - 30 * day, lastPromptedVersion: "1.5.0",
            currentVersion: "1.6.0", nowMillis: now))
    }

    func testEligibleAfterCooldownOnNewVersion() {
        XCTAssertTrue(ReviewPromptPolicy.isEligible(
            goodRideCount: 10, lastPromptedAtMillis: now - 91 * day, lastPromptedVersion: "1.5.0",
            currentVersion: "1.6.0", nowMillis: now))
    }

    func testCooldownBoundaryExactly90DaysIsEligible() {
        XCTAssertTrue(ReviewPromptPolicy.isEligible(
            goodRideCount: 5, lastPromptedAtMillis: now - 90 * day, lastPromptedVersion: "1.5.0",
            currentVersion: "1.6.0", nowMillis: now))
    }
}
