import XCTest
@testable import track_me_ios

final class GroupBackoffTests: XCTestCase {
    func testRetryDelayUsesExponentialBackoffAndJitter() {
        var backoff = GroupBackoff(random: { 1 })

        XCTAssertEqual(backoff.nextDelay(), 2)
        XCTAssertEqual(backoff.nextDelay(), 4)
        XCTAssertEqual(backoff.nextDelay(retryAfter: 120), 60)
    }

    func testOnlyTransientRelayFailuresAreRetryable() {
        XCTAssertTrue(GroupBackoff.isRetryable(statusCode: 429, code: nil))
        XCTAssertTrue(GroupBackoff.isRetryable(statusCode: 503, code: "REDIS_UNAVAILABLE"))
        XCTAssertTrue(GroupBackoff.isRetryable(statusCode: 500, code: nil))
        XCTAssertFalse(GroupBackoff.isRetryable(statusCode: 401, code: nil))
        XCTAssertFalse(GroupBackoff.isRetryable(statusCode: 404, code: nil))
        XCTAssertFalse(GroupBackoff.isRetryable(statusCode: 400, code: "GROUP_FULL"))
    }
}
