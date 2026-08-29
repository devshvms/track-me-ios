import XCTest
@testable import track_me_ios

/// TASK-230. The rider is taught mid-ride that moving and total are different numbers; the pair has
/// to survive the ride ending, and a ride that never paused has to show them equal rather than
/// suppress one — suppression is what made a single unlabelled figure ambiguous. Mirrors Android's
/// `HistoryDurationTest`.
final class RideDurationsTests: XCTestCase {

    private func ride(startOffset: TimeInterval, endOffset: TimeInterval?, movingMillis: Int64?) -> Ride {
        let base = Date(timeIntervalSince1970: 1_756_000_000)
        let ride = Ride(startTime: base.addingTimeInterval(startOffset))
        ride.endTime = endOffset.map { base.addingTimeInterval($0) }
        ride.movingDurationMillis = movingMillis
        ride.distanceMeters = 5_000
        ride.maxSpeedMps = 12
        ride.avgSpeedMps = 8
        ride.pointCount = 120
        return ride
    }

    func testAPausedRideShowsMovingAndTotalAsADifferingPair() {
        let subject = ride(startOffset: 0, endOffset: 1_200, movingMillis: 300_000)
        XCTAssertEqual(RideDurations.movingSeconds(for: subject), 300, accuracy: 0.001)
        XCTAssertEqual(RideDurations.totalElapsedSeconds(for: subject) ?? 0, 1_200, accuracy: 0.001)
    }

    func testARideWithNoPauseShowsBothFiguresEqualRatherThanSuppressingOne() {
        let subject = ride(startOffset: 0, endOffset: 300, movingMillis: 300_000)
        XCTAssertEqual(
            RideDurations.movingSeconds(for: subject),
            RideDurations.totalElapsedSeconds(for: subject) ?? -1,
            accuracy: 0.001
        )
    }

    func testARideWithNoUsableEndHasNoTotal() {
        XCTAssertNil(RideDurations.totalElapsedSeconds(for: ride(startOffset: 0, endOffset: nil, movingMillis: 1)))
        // An end at or before the start is not a finished ride.
        XCTAssertNil(RideDurations.totalElapsedSeconds(for: ride(startOffset: 0, endOffset: 0, movingMillis: 1)))
        XCTAssertNil(RideDurations.totalElapsedSeconds(for: ride(startOffset: 100, endOffset: 50, movingMillis: 1)))
    }

    func testTotalNeedsNoReconciliationSoAnUnrebuiltRideStillShowsOneRealNumber() {
        let subject = Ride(startTime: Date(timeIntervalSince1970: 1_756_000_000))
        subject.endTime = subject.startTime.addingTimeInterval(1_200)
        XCTAssertEqual(RideDurations.totalElapsedSeconds(for: subject) ?? 0, 1_200, accuracy: 0.001)
    }
}
