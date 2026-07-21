import XCTest
@testable import track_me_ios

/// Unit tests for the pure A1 reducer (iOS). Mirrors the Android `RideStatsReducerTest`:
/// accumulation, PR detection, idempotency, milestones, Monday week boundaries (incl. a DST
/// zone), and the weekly streak. Uses a fixed UTC Monday-anchored calendar for determinism.
final class RideStatsReducerTests: XCTestCase {

    private func cal(_ tz: String = "UTC") -> Calendar {
        WeekKey.mondayAnchored(timeZone: TimeZone(identifier: tz)!)
    }

    /// Epoch millis for a Y-M-D at noon UTC (or given zone).
    private func millis(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12, tz: String = "UTC") -> Int64 {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = hour
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: tz)!
        let date = gregorian.date(from: c)!
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    private func summary(_ id: String, _ at: Int64, duration: Int64 = 60_000, dist: Double = 1000.0) -> GoodRideSummary {
        GoodRideSummary(rideId: id, finishedAtMillis: at, durationMillis: duration, distanceMeters: dist)
    }

    func testFirstRideIsFirstNoPrStreakOne() {
        let (stats, t) = RideStatsReducer.reduce(RideStats(), summary("1", millis(2026, 7, 20)), cal())
        XCTAssertTrue(t.isFirstRide)
        XCTAssertFalse(t.isDistancePR)
        XCTAssertFalse(t.isDurationPR)
        XCTAssertEqual(t.totalRides, 1)
        XCTAssertEqual(t.streakWeeks, 1)
        XCTAssertTrue(t.isFirstRideOfWeek)
        XCTAssertTrue(t.streakAdvanced)
        XCTAssertEqual(stats.longestDistanceMeters, 1000.0, accuracy: 0.001)
    }

    func testSecondRideLongerSetsBothPRs() {
        var stats = RideStats()
        stats = RideStatsReducer.reduce(stats, summary("1", millis(2026, 7, 20), duration: 60_000, dist: 1000), cal()).0
        let (_, t) = RideStatsReducer.reduce(stats, summary("2", millis(2026, 7, 21), duration: 120_000, dist: 2000), cal())
        XCTAssertTrue(t.isDistancePR)
        XCTAssertTrue(t.isDurationPR)
    }

    func testEqualToRecordIsNotPr() {
        var stats = RideStats()
        stats = RideStatsReducer.reduce(stats, summary("1", millis(2026, 7, 20), duration: 60_000, dist: 1000), cal()).0
        let (_, t) = RideStatsReducer.reduce(stats, summary("2", millis(2026, 7, 21), duration: 60_000, dist: 1000), cal())
        XCTAssertFalse(t.isDistancePR)
        XCTAssertFalse(t.isDurationPR)
    }

    func testDuplicateRideIdIsNoOp() {
        var stats = RideStats()
        stats = RideStatsReducer.reduce(stats, summary("1", millis(2026, 7, 20)), cal()).0
        let (after, t) = RideStatsReducer.reduce(stats, summary("1", millis(2026, 7, 20)), cal())
        XCTAssertTrue(t.alreadyProcessed)
        XCTAssertEqual(after.totalRides, 1)
        XCTAssertEqual(after, stats)
    }

    func testMilestoneFiresOnThreshold() {
        var stats = RideStats()
        var last: Int? = nil
        for i in 1...10 {
            let r = RideStatsReducer.reduce(stats, summary("\(i)", millis(2026, 7, 20 + i)), cal())
            stats = r.0
            if let m = r.1.milestoneRideCount { last = m }
        }
        XCTAssertEqual(last, 10)
        let (_, t11) = RideStatsReducer.reduce(stats, summary("11", millis(2026, 8, 15)), cal())
        XCTAssertNil(t11.milestoneRideCount)
    }

    func testSameWeekDoesNotAdvanceStreak() {
        var stats = RideStats()
        stats = RideStatsReducer.reduce(stats, summary("1", millis(2026, 7, 20)), cal()).0        // Mon
        let (_, t) = RideStatsReducer.reduce(stats, summary("2", millis(2026, 7, 22)), cal())      // Wed same wk
        XCTAssertFalse(t.isFirstRideOfWeek)
        XCTAssertFalse(t.streakAdvanced)
        XCTAssertEqual(t.streakWeeks, 1)
        XCTAssertEqual(t.weekRideCount, 2)
    }

    func testConsecutiveWeeksExtendStreak() {
        var stats = RideStats()
        stats = RideStatsReducer.reduce(stats, summary("1", millis(2026, 7, 20)), cal()).0
        stats = RideStatsReducer.reduce(stats, summary("2", millis(2026, 7, 30)), cal()).0   // next week
        let (_, t) = RideStatsReducer.reduce(stats, summary("3", millis(2026, 8, 4)), cal()) // week after
        XCTAssertEqual(t.streakWeeks, 3)
        XCTAssertTrue(t.streakAdvanced)
    }

    func testSingleMissedWeekIsForgivenByFreeze() {
        // B3: one isolated miss is auto-frozen (parity with Android).
        var stats = RideStats()
        stats = RideStatsReducer.reduce(stats, summary("1", millis(2026, 7, 20)), cal()).0
        let (after, t) = RideStatsReducer.reduce(stats, summary("2", millis(2026, 8, 3)), cal()) // skipped a week
        XCTAssertEqual(t.streakWeeks, 2)
        XCTAssertTrue(t.streakFroze)
        XCTAssertFalse(after.freezeAvailable)
    }

    func testTwoMissedWeeksResetStreak() {
        var stats = RideStats()
        stats = RideStatsReducer.reduce(stats, summary("1", millis(2026, 7, 20)), cal()).0
        let (after, t) = RideStatsReducer.reduce(stats, summary("2", millis(2026, 8, 10)), cal()) // skipped two weeks
        XCTAssertEqual(t.streakWeeks, 1)
        XCTAssertFalse(t.streakFroze)
        XCTAssertTrue(after.freezeAvailable)
    }

    func testTwoConsecutiveSingleMissesSecondResets() {
        var stats = RideStats()
        stats = RideStatsReducer.reduce(stats, summary("1", millis(2026, 7, 20)), cal()).0
        stats = RideStatsReducer.reduce(stats, summary("2", millis(2026, 8, 3)), cal()).0  // forgiven -> 2
        let (_, t) = RideStatsReducer.reduce(stats, summary("3", millis(2026, 8, 17)), cal()) // miss again, no token
        XCTAssertEqual(t.streakWeeks, 1)
        XCTAssertFalse(t.streakFroze)
    }

    func testActiveWeekRefillsFreeze() {
        var stats = RideStats()
        stats = RideStatsReducer.reduce(stats, summary("1", millis(2026, 7, 20)), cal()).0
        stats = RideStatsReducer.reduce(stats, summary("2", millis(2026, 8, 3)), cal()).0  // forgiven -> 2, token used
        stats = RideStatsReducer.reduce(stats, summary("3", millis(2026, 8, 10)), cal()).0 // consecutive -> 3, refilled
        XCTAssertTrue(stats.freezeAvailable)
        let (_, t) = RideStatsReducer.reduce(stats, summary("4", millis(2026, 8, 24)), cal()) // single miss again
        XCTAssertEqual(t.streakWeeks, 4)
        XCTAssertTrue(t.streakFroze)
    }

    func testTimezoneAffectsWeekAssignment() {
        // 2026-07-20 00:30 UTC is still Sunday in New York -> previous Monday-week (7 days earlier).
        let at = millis(2026, 7, 20, hour: 0, tz: "UTC") + 30 * 60 * 1000
        let d = Date(timeIntervalSince1970: Double(at) / 1000.0)
        let startUtc = WeekKey.weekStartEpochDay(d, calendar: cal("UTC"))
        let startNy = WeekKey.weekStartEpochDay(d, calendar: cal("America/New_York"))
        XCTAssertEqual(startUtc - startNy, 7)
    }

    func testWeekLabelIsoMondayAnchored() {
        let d = Date(timeIntervalSince1970: Double(millis(2026, 7, 20)) / 1000.0)
        let ws = WeekKey.weekStartEpochDay(d, calendar: cal())
        XCTAssertEqual(WeekKey.label(weekStartEpochDay: ws, calendar: cal()), "2026-W30")
    }

    func testProcessedIdsAreBounded() {
        var stats = RideStats()
        let n = RideStats.maxProcessedIds + 50
        for i in 1...n {
            stats = RideStatsReducer.reduce(stats, summary("\(i)", millis(2026, 1, 1) + Int64(i) * 86_400_000), cal()).0
        }
        XCTAssertLessThanOrEqual(stats.processedRideIds.count, RideStats.maxProcessedIds)
        XCTAssertTrue(stats.processedRideIds.contains("\(n)"))
        XCTAssertFalse(stats.processedRideIds.contains("1"))
    }
}
