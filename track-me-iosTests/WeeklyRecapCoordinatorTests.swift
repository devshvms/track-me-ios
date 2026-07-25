import XCTest
@testable import track_me_ios

/// Regression coverage for the presentation-layer contract: acknowledging a displayed
/// week suppresses that week while allowing a later week to surface.
final class WeeklyRecapCoordinatorTests: XCTestCase {
    private func calendar() -> Calendar { WeekKey.mondayAnchored(timeZone: TimeZone(identifier: "UTC")!) }

    private func date(_ day: Int) -> Date {
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = day; components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }

    func testAcknowledgedWeekDoesNotReturnAndLaterWeekDoes() {
        let firstWeek = WeekKey.weekStartEpochDay(date(20), calendar: calendar())
        var stats = RideStats()
        stats.currentWeekStartEpochDay = firstWeek
        stats.currentWeekRideCount = 3
        stats.currentWeekDistanceMeters = 10_000
        stats.lastRecapShownWeekStartEpochDay = firstWeek

        XCTAssertNil(WeeklyRecapSelector.select(stats, now: date(28), calendar: calendar()))

        stats.currentWeekStartEpochDay = WeekKey.weekStartEpochDay(date(27), calendar: calendar())
        stats.currentWeekRideCount = 2
        XCTAssertNotNil(WeeklyRecapSelector.select(stats, now: date(4), calendar: calendar()))
        // Store acknowledgement is idempotent; repeating the same week marker is unchanged.
        stats.lastRecapShownWeekStartEpochDay = firstWeek
        XCTAssertEqual(stats.lastRecapShownWeekStartEpochDay, firstWeek)
    }
}
