import XCTest
@testable import track_me_ios

final class MultiDayReminderTests: XCTestCase {
    func testSelectedDaysAndDuplicateSuppression() {
        let settings = ActivityReminder.Settings(enabled: true, daysOfWeek: [1, 3, 5])
        for day in 1...7 {
            XCTAssertEqual([1, 3, 5].contains(day),
                ActivityReminder.shouldFire(settings: settings, nowDayOfWeek: day,
                    nowEpochDay: 100, lastFiredEpochDay: nil))
        }
        XCTAssertFalse(ActivityReminder.shouldFire(settings: settings, nowDayOfWeek: 3,
            nowEpochDay: 100, lastFiredEpochDay: 100))
    }

    func testLegacyDayAndInvalidSelection() {
        let legacy = ActivityReminder.Settings(dayOfWeek: 2)
        XCTAssertEqual(legacy.selectedDays, [2])
        XCTAssertFalse(legacy.enabled)
        XCTAssertFalse(ActivityReminder.Settings(enabled: true, daysOfWeek: []).isValid)
        XCTAssertFalse(ActivityReminder.Settings(enabled: true, daysOfWeek: [0, 1]).isValid)
    }
}
