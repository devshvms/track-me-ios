import XCTest
import CoreLocation
@testable import track_me_ios

final class AdaptiveGpsThrottlePolicyTests: XCTestCase {

    func testThrottleConstantsAndThresholds() {
        // Active mode: best accuracy, 2-meter distance filter
        XCTAssertEqual(AdaptiveGpsThrottlePolicy.activeAccuracy, kCLLocationAccuracyBest)
        XCTAssertEqual(AdaptiveGpsThrottlePolicy.activeDistanceFilter, 2.0)

        // Throttled stationary mode: 10-meter accuracy, 15-meter distance filter
        XCTAssertEqual(AdaptiveGpsThrottlePolicy.throttledAccuracy, kCLLocationAccuracyNearestTenMeters)
        XCTAssertEqual(AdaptiveGpsThrottlePolicy.throttledDistanceFilter, 15.0)

        // Threshold before throttling kicks in is exactly 180 seconds (3 minutes)
        XCTAssertEqual(AdaptiveGpsThrottlePolicy.stationaryThrottleThreshold, 180.0)
    }

    func testShouldThrottle_requiresStationaryAndFull3MinutesStillness() {
        // Moving user should never be throttled
        XCTAssertFalse(
            AdaptiveGpsThrottlePolicy.shouldThrottle(
                isStationary: false,
                stillnessDuration: 250.0
            )
        )

        // Stationary user under 3 minutes (e.g. 45s traffic stop) remains in active high accuracy
        XCTAssertFalse(
            AdaptiveGpsThrottlePolicy.shouldThrottle(
                isStationary: true,
                stillnessDuration: 45.0
            )
        )
        XCTAssertFalse(
            AdaptiveGpsThrottlePolicy.shouldThrottle(
                isStationary: true,
                stillnessDuration: 179.9
            )
        )

        // Stationary user reaching or exceeding 180 seconds is throttled
        XCTAssertTrue(
            AdaptiveGpsThrottlePolicy.shouldThrottle(
                isStationary: true,
                stillnessDuration: 180.0
            )
        )
        XCTAssertTrue(
            AdaptiveGpsThrottlePolicy.shouldThrottle(
                isStationary: true,
                stillnessDuration: 600.0 // 10 minutes
            )
        )
    }

    func testShouldRestore_triggersInstantlyOnMovement() {
        // If not currently throttled, no restoration needed
        XCTAssertFalse(
            AdaptiveGpsThrottlePolicy.shouldRestore(
                isCurrentlyThrottled: false,
                isStationary: false
            )
        )

        // If currently throttled and still stationary, stay throttled
        XCTAssertFalse(
            AdaptiveGpsThrottlePolicy.shouldRestore(
                isCurrentlyThrottled: true,
                isStationary: true
            )
        )

        // If currently throttled and motion is detected, restore immediately!
        XCTAssertTrue(
            AdaptiveGpsThrottlePolicy.shouldRestore(
                isCurrentlyThrottled: true,
                isStationary: false
            )
        )
    }
}
