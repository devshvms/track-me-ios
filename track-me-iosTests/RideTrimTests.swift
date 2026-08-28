import XCTest
@testable import track_me_ios

/// TASK-253. The window that hides the recording a rider forgot to stop.
///
/// Mirrors Android's `RideTrimTest` case for case, so the two platforms cannot drift on what counts
/// as "stopped riding". The risk is asymmetric: leaving a flat tail on a chart is untidy, while
/// hiding a real part of someone's route is a loss they cannot see happening — so most of these
/// cases are about *not* trimming.
final class RideTrimTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func point(_ second: Int, speed: Double, paused: Bool = false) -> GPSPoint {
        GPSPoint(
            latitude: 12.97 + Double(second) * 1e-5,
            longitude: 77.59 + Double(second) * 1e-5,
            altitude: 900,
            accuracy: 5,
            speed: speed,
            timestamp: start.addingTimeInterval(Double(second)),
            isPaused: paused
        )
    }

    /// Stopped, riding, stopped.
    private func ride(leadStill: Int, moving: Int, trailStill: Int) -> [GPSPoint] {
        var points: [GPSPoint] = []
        var t = 0
        for _ in 0..<leadStill { points.append(point(t, speed: 0, paused: true)); t += 1 }
        for _ in 0..<moving { points.append(point(t, speed: 6)); t += 1 }
        for _ in 0..<trailStill { points.append(point(t, speed: 0, paused: true)); t += 1 }
        return points
    }

    func testTheForgottenTailIsCut() {
        // The case shvm described: rode 10 minutes, left it recording for 30 after getting home.
        let trim = RideTrimmer.window(for: ride(leadStill: 0, moving: 600, trailStill: 1_800))
        XCTAssertTrue(trim.isTrimmed)
        XCTAssertEqual(trim.startIndex, 0)
        XCTAssertEqual(trim.endIndex, 599)
        XCTAssertEqual(trim.trailingSeconds, 1_800, accuracy: 0.5)
        XCTAssertEqual(trim.leadingSeconds, 0, accuracy: 0.5)
    }

    func testASlowStartBeforeSettingOffIsCutToo() {
        let trim = RideTrimmer.window(for: ride(leadStill: 300, moving: 600, trailStill: 0))
        XCTAssertEqual(trim.startIndex, 300)
        XCTAssertEqual(trim.leadingSeconds, 300, accuracy: 0.5)
    }

    func testAPauseInTheMiddleIsNeverCut() {
        // A traffic light. Cutting an interior stop would teleport the route across the junction,
        // which is a worse lie than a flat line on a chart.
        var points: [GPSPoint] = []
        for i in 0..<300 { points.append(point(i, speed: 6)) }
        for i in 300..<600 { points.append(point(i, speed: 0, paused: true)) }
        for i in 600..<900 { points.append(point(i, speed: 6)) }

        let trim = RideTrimmer.window(for: points)
        XCTAssertFalse(trim.isTrimmed, "neither end is stationary")
        XCTAssertEqual(trim.startIndex, 0)
        XCTAssertEqual(trim.endIndex, 899)
    }

    func testABriefWaitAtTheKerbIsLeftAlone() {
        // 30 seconds is a level crossing, not a forgotten recording.
        let trim = RideTrimmer.window(for: ride(leadStill: 30, moving: 600, trailStill: 30))
        XCTAssertFalse(trim.isTrimmed)
    }

    func testATailAutoPauseNeverFlaggedIsStillCutOnSpeed() {
        // Auto-pause switched off: stationary but unflagged, which is why isPaused alone cannot
        // carry this.
        var points: [GPSPoint] = []
        for i in 0..<600 { points.append(point(i, speed: 6)) }
        for i in 600..<1_200 { points.append(point(i, speed: 0.1, paused: false)) }

        let trim = RideTrimmer.window(for: points)
        XCTAssertTrue(trim.isTrimmed)
        XCTAssertEqual(trim.endIndex, 599)
    }

    func testARideThatNeverMovedIsShownWholeRatherThanBlanked() {
        // Returning an empty window would draw nothing and read as a bug; showing it all lets the
        // rider see the truth for themselves.
        let points = ride(leadStill: 600, moving: 0, trailStill: 0)
        let trim = RideTrimmer.window(for: points)
        XCTAssertFalse(trim.isTrimmed)
        XCTAssertEqual(trim.startIndex, 0)
        XCTAssertEqual(trim.endIndex, points.count - 1)
    }

    func testAVeryShortRideIsNeverTrimmed() {
        let trim = RideTrimmer.window(for: [point(0, speed: 0, paused: true), point(1, speed: 0, paused: true)])
        XCTAssertFalse(trim.isTrimmed)
    }

    func testAnEmptyRideDoesNotCrash() {
        let trim = RideTrimmer.window(for: [])
        XCTAssertFalse(trim.isTrimmed)
        XCTAssertEqual(trim.startIndex, 0)
        XCTAssertEqual(trim.endIndex, 0)
    }

    func testTheWindowIsAlwaysNonEmptyAndOrdered() {
        for lead in [0, 5, 300] {
            for trail in [0, 5, 1_800] {
                let trim = RideTrimmer.window(for: ride(leadStill: lead, moving: 600, trailStill: trail))
                XCTAssertGreaterThanOrEqual(trim.endIndex, trim.startIndex, "lead=\(lead) trail=\(trail)")
            }
        }
    }

    func testTheTwoPlatformsAgreeOnTheMinimumRun() {
        // Android's DEFAULT_MINIMUM_TRIM_RUN_MILLIS is 120_000. If one side moves, this is the
        // reminder that the other has to move with it.
        XCTAssertEqual(RideTrimmer.minimumRunSeconds, 120)
    }
}
