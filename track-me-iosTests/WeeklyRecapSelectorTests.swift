import XCTest
@testable import track_me_ios

/// Unit tests for the pure B2 `WeeklyRecapSelector` (iOS). Mirrors the Android
/// `WeeklyRecapSelectorTest`: only a completed, non-empty, un-acknowledged week produces a recap.
final class WeeklyRecapSelectorTests: XCTestCase {

    private func cal() -> Calendar { WeekKey.mondayAnchored(timeZone: TimeZone(identifier: "UTC")!) }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
        var g = Calendar(identifier: .gregorian); g.timeZone = TimeZone(identifier: "UTC")!
        return g.date(from: c)!
    }

    private func statsForWeek(_ y: Int, _ m: Int, _ d: Int, rides: Int = 3, streak: Int = 2, shown: Int = 0) -> RideStats {
        var s = RideStats()
        s.totalRides = rides
        s.currentWeekStartEpochDay = WeekKey.weekStartEpochDay(date(y, m, d), calendar: cal())
        s.currentWeekRideCount = rides
        s.currentWeekDistanceMeters = 12_000
        s.streakWeeks = streak
        s.lastRecapShownWeekStartEpochDay = shown
        return s
    }

    func testCompletedWeekWithRidesProducesRecap() {
        let stats = statsForWeek(2026, 7, 20)                 // Monday
        let recap = WeeklyRecapSelector.select(stats, now: date(2026, 7, 28), calendar: cal())!
        XCTAssertEqual(recap.weekKey, "2026-W30")
        XCTAssertEqual(recap.rideCount, 3)
        XCTAssertEqual(recap.streakWeeks, 2)
    }

    func testStillInsideActiveWeekProducesNothing() {
        let stats = statsForWeek(2026, 7, 20)
        XCTAssertNil(WeeklyRecapSelector.select(stats, now: date(2026, 7, 23), calendar: cal()))
    }

    func testNeverRodeProducesNothing() {
        XCTAssertNil(WeeklyRecapSelector.select(RideStats(), now: date(2026, 7, 28), calendar: cal()))
    }

    func testZeroRideWeekProducesNothing() {
        var stats = statsForWeek(2026, 7, 20); stats.currentWeekRideCount = 0
        XCTAssertNil(WeeklyRecapSelector.select(stats, now: date(2026, 7, 28), calendar: cal()))
    }

    func testAcknowledgedWeekProducesNothing() {
        let ws = WeekKey.weekStartEpochDay(date(2026, 7, 20), calendar: cal())
        let stats = statsForWeek(2026, 7, 20, shown: ws)
        XCTAssertNil(WeeklyRecapSelector.select(stats, now: date(2026, 7, 28), calendar: cal()))
    }
}
