import XCTest
@testable import track_me_ios

/// TASK-257. Whether the straight line between two fixes represents a stretch never recorded.
///
/// Mirrors Android's `RideGapsTest` case for case. The failure directions are not symmetric, so most
/// of these guard the dangerous one: a false negative is a cosmetically solid line, a false positive
/// draws a real part of someone's ride as though we had not recorded it.
final class RideGapsTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func point(_ second: Int, lat: Double, lon: Double, paused: Bool = false) -> GPSPoint {
        GPSPoint(latitude: lat, longitude: lon, altitude: 0, accuracy: 5, speed: 0,
                 timestamp: start.addingTimeInterval(Double(second)), isPaused: paused)
    }

    /// ~111 m per 0.001 degree of latitude.
    private func northOf(_ base: GPSPoint, metres: Double, afterSeconds: Int) -> GPSPoint {
        point(Int(base.timestamp.timeIntervalSince(start)) + afterSeconds,
              lat: base.latitude + metres / 111_320.0, lon: base.longitude)
    }

    func testAWalkAcrossAManualPauseIsNotCaughtBySpeedAndMustNotBe() {
        // shvm's case: ~600 m over four minutes is 9 km/h — ordinary walking, indistinguishable by
        // speed from walking while recording. This is the limit of the rule, and the reason a manual
        // pause now writes a flagged point instead. Asserting the negative keeps that reasoning
        // attached, so nobody lowers the ceiling to catch it and starts dotting real walks.
        let a = point(0, lat: 12.9700, lon: 77.5900)
        let b = northOf(a, metres: 600, afterSeconds: 240)
        XCTAssertFalse(RideGaps.isUnrecordedGap(from: a, to: b, persona: .walk))
    }

    func testATeleportAcrossAPauseIsCaught() {
        let a = point(0, lat: 12.9700, lon: 77.5900)
        let b = northOf(a, metres: 6_000, afterSeconds: 240) // 90 km/h on a walk
        XCTAssertTrue(RideGaps.isUnrecordedGap(from: a, to: b, persona: .walk))
    }

    func testASparseButOrdinaryStretchIsNotAGap() {
        // Time alone would have dotted this and undercounted a stretch really ridden.
        let a = point(0, lat: 12.9700, lon: 77.5900)
        let b = northOf(a, metres: 150, afterSeconds: 30) // 18 km/h
        XCTAssertFalse(RideGaps.isUnrecordedGap(from: a, to: b, persona: .cycling))
    }

    func testASingleJitteryFixIsNotAGap() {
        // One bad fix at 1 Hz implies hundreds of km/h. This is why the rule is AND, never OR.
        let a = point(0, lat: 12.9700, lon: 77.5900)
        let b = northOf(a, metres: 400, afterSeconds: 1)
        XCTAssertFalse(RideGaps.isUnrecordedGap(from: a, to: b, persona: .walk))
    }

    func testTheCeilingIsPersonaAware() {
        let a = point(0, lat: 12.9700, lon: 77.5900)
        let b = northOf(a, metres: 1_000, afterSeconds: 60) // 60 km/h
        XCTAssertTrue(RideGaps.isUnrecordedGap(from: a, to: b, persona: .walk))
        XCTAssertFalse(RideGaps.isUnrecordedGap(from: a, to: b, persona: .carDrive))
    }

    func testAutoTakesTheMostPermissiveCeiling() {
        XCTAssertEqual(
            RideGaps.maxPlausibleSpeedMetersPerSecond(for: .auto),
            RideGaps.maxPlausibleSpeedMetersPerSecond(for: .carDrive)
        )
    }

    func testALongStopThatDidNotMoveIsNotAGap() {
        let a = point(0, lat: 12.9700, lon: 77.5900)
        let b = point(600, lat: 12.9700, lon: 77.5900)
        XCTAssertFalse(RideGaps.isUnrecordedGap(from: a, to: b, persona: .walk))
    }

    func testRunsSplitAtGapsAndNowhereElse() {
        let p0 = point(0, lat: 12.9700, lon: 77.5900)
        let p1 = northOf(p0, metres: 20, afterSeconds: 5)
        let p2 = northOf(p1, metres: 20, afterSeconds: 5)
        let far = northOf(p2, metres: 3_000, afterSeconds: 120)
        let p4 = northOf(far, metres: 20, afterSeconds: 5)

        let runs = RideGaps.recordedRuns([p0, p1, p2, far, p4], persona: .walk)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].count, 3)
        XCTAssertEqual(runs[1].count, 2)
    }

    func testEdgeInputsDoNotCrash() {
        XCTAssertTrue(RideGaps.recordedRuns([], persona: .auto).isEmpty)
        XCTAssertEqual(RideGaps.recordedRuns([point(0, lat: 1, lon: 1)], persona: .auto).count, 1)
    }

    func testTheTwoPlatformsAgreeOnTheThreshold() {
        // Android's GAP_THRESHOLD_MILLIS is 25_000, and it is the same number the "GPS signal gaps"
        // count already uses. If one moves, this is the reminder that the others must.
        XCTAssertEqual(RideGaps.gapThresholdSeconds, 25)
        XCTAssertEqual(RideGaps.gapThresholdSeconds, ChartAccessibility.gapThresholdSeconds)
    }
}

/// TASK-259, from review. Moving time had four implementations across the two platforms and they
/// disagreed: Android counted every gap on three paths, capped at 15 s on a fourth and 60 s on a
/// fifth, and iOS carried its own 60 s. One ride reconstructed to different durations depending on
/// which code path — and which platform — last touched it.
final class MovingTimeRuleTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func point(_ second: Int, paused: Bool = false) -> GPSPoint {
        GPSPoint(latitude: 12.97, longitude: 77.59, altitude: 0, accuracy: 5, speed: 5,
                 timestamp: start.addingTimeInterval(Double(second)), isPaused: paused)
    }

    func testTheThresholdMatchesAndroidAndTheAppsOwnGapDefinition() {
        // Android's countsAsMovingTime uses RideGaps.GAP_THRESHOLD_MILLIS = 25_000. If either side
        // moves, this is the reminder the other must move with it.
        XCTAssertEqual(RideGaps.gapThresholdSeconds, 25)
        XCTAssertEqual(RideGaps.gapThresholdSeconds, ChartAccessibility.gapThresholdSeconds)
    }

    func testALongGapIsNotCountedAsMovingTime() {
        // 2 seconds of real movement, then a 138-second gap. Only the 2 seconds are moving time.
        let aggregate = RideMetrics.reconstructed(from: [point(0), point(1), point(2), point(140)])
        XCTAssertEqual(aggregate.movingDurationMillis, 2_000)
    }

    func testAPausedEndpointIsExcludedOnEitherSide() {
        let aggregate = RideMetrics.reconstructed(from: [
            point(0), point(1), point(2, paused: true), point(3), point(4),
        ])
        // 0->1 counts; 1->2 and 2->3 touch the paused point; 3->4 counts.
        XCTAssertEqual(aggregate.movingDurationMillis, 2_000)
    }

    func testTheOldSixtySecondCapWouldHaveInflatedThis() {
        // A 40-second gap: under the old iOS cap it counted as moving time, over the shared rule it
        // does not. This is the behaviour the unification deliberately changes.
        let aggregate = RideMetrics.reconstructed(from: [point(0), point(40)])
        XCTAssertEqual(aggregate.movingDurationMillis, 0)
    }
}
