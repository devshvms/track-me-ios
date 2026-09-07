import XCTest
@testable import track_me_ios

/// SCOPE_1.8.7 §6.1.2 scenarios 8 and 10a — the flagship Class C.
///
/// Case for case with Android's `WeeklyRecapNoticeTest`. The recap already existed and was already
/// deduped per week; what it was not is reachable — it appeared only if you opened the app on a
/// calm Monday, which is exactly the population that needs it least.
@MainActor
final class WeeklyRecapNoticeTests: XCTestCase {

    private let week = 20_000

    private func recap(rides: Int = 3, weekStart: Int? = nil) -> WeeklyRecap {
        WeeklyRecap(
            weekKey: "2026-W30",
            weekStartEpochDay: weekStart ?? week,
            rideCount: rides,
            distanceMeters: 41_200,
            streakWeeks: 6
        )
    }

    func testARealWeekWithinBudgetIsNotified() {
        XCTAssertTrue(WeeklyRecapNotice.shouldNotify(
            recap: recap(),
            nowMillis: NotificationBudget.proactiveIntervalMillis,
            lastProactiveSentAtMillis: 0,
            alreadyNotifiedWeekStart: nil
        ))
    }

    func testAZeroRideWeekIsSilent() {
        // "You did nothing last week" is the exact message §4.2 N2 forbids — and it would arrive
        // automatically, every week, for anyone who had stopped riding.
        XCTAssertFalse(WeeklyRecapNotice.shouldNotify(
            recap: recap(rides: 0),
            nowMillis: NotificationBudget.proactiveIntervalMillis,
            lastProactiveSentAtMillis: nil,
            alreadyNotifiedWeekStart: nil
        ))
    }

    func testTheBudgetSuppressesARecapThatIsOtherwiseReady() {
        XCTAssertFalse(WeeklyRecapNotice.shouldNotify(
            recap: recap(),
            nowMillis: NotificationBudget.proactiveIntervalMillis - 1,
            lastProactiveSentAtMillis: 0,
            alreadyNotifiedWeekStart: nil
        ))
    }

    func testASuppressedRecapIsStillEligibleOnceTheWeekOpens() {
        // Skipping is free: a recap the budget refuses is not consumed.
        let ready = recap()
        XCTAssertFalse(WeeklyRecapNotice.shouldNotify(
            recap: ready, nowMillis: 1_000, lastProactiveSentAtMillis: 0, alreadyNotifiedWeekStart: nil
        ))
        XCTAssertTrue(WeeklyRecapNotice.shouldNotify(
            recap: ready,
            nowMillis: NotificationBudget.proactiveIntervalMillis,
            lastProactiveSentAtMillis: 0,
            alreadyNotifiedWeekStart: nil
        ))
    }

    func testAWeekIsNeverAnnouncedTwiceButTheNextWeekMayBe() {
        XCTAssertFalse(WeeklyRecapNotice.shouldNotify(
            recap: recap(),
            nowMillis: NotificationBudget.proactiveIntervalMillis * 4,
            lastProactiveSentAtMillis: 0,
            alreadyNotifiedWeekStart: week
        ))
        XCTAssertTrue(WeeklyRecapNotice.shouldNotify(
            recap: recap(weekStart: week + 7),
            nowMillis: NotificationBudget.proactiveIntervalMillis * 4,
            lastProactiveSentAtMillis: 0,
            alreadyNotifiedWeekStart: week
        ))
    }

    func testAFirstRecapIsNotOwedAWeekOfSilenceFirst() {
        XCTAssertTrue(WeeklyRecapNotice.shouldNotify(
            recap: recap(), nowMillis: 0, lastProactiveSentAtMillis: nil, alreadyNotifiedWeekStart: nil
        ))
    }

    // MARK: - 10a, the line that replaced a cut notification

    func testProximityIsMentionedWhenItIsCloseAndTrue() {
        XCTAssertEqual(
            WeeklyRecapNotice.proximityLine(minutesToNextLevel: 20, nextLevelName: "Explorer"),
            .init(minutes: 20, levelName: "Explorer")
        )
    }

    func testNothingIsSaidAtTheMaximumLevel() {
        XCTAssertNil(WeeklyRecapNotice.proximityLine(minutesToNextLevel: nil, nextLevelName: "Explorer"))
        XCTAssertNil(WeeklyRecapNotice.proximityLine(minutesToNextLevel: 20, nextLevelName: nil))
        XCTAssertNil(WeeklyRecapNotice.proximityLine(minutesToNextLevel: 20, nextLevelName: "  "))
    }

    func testAnAlreadyReachedLevelIsNotAnnouncedAsZeroMinutesAway() {
        // The reveal already covered it. "0 minutes from Explorer" is the app failing to notice
        // something the user has already done.
        XCTAssertNil(WeeklyRecapNotice.proximityLine(minutesToNextLevel: 0, nextLevelName: "Explorer"))
        XCTAssertNil(WeeklyRecapNotice.proximityLine(minutesToNextLevel: -30, nextLevelName: "Explorer"))
    }

    func testADistantLevelIsLeftUnmentioned() {
        XCTAssertNil(WeeklyRecapNotice.proximityLine(
            minutesToNextLevel: WeeklyRecapNotice.maxMinutesWorthMentioning + 1, nextLevelName: "Explorer"
        ))
        XCTAssertEqual(
            WeeklyRecapNotice.proximityLine(
                minutesToNextLevel: WeeklyRecapNotice.maxMinutesWorthMentioning, nextLevelName: "Explorer"
            ),
            .init(minutes: WeeklyRecapNotice.maxMinutesWorthMentioning, levelName: "Explorer")
        )
    }

    // MARK: - The iOS-specific half: scheduling ahead rather than posting now

    func testADeliveryDateInThePastIsNeverScheduled() {
        // A calendar trigger whose components are already past does not fire at all — not
        // immediately, not ever. Getting this wrong means the recap silently never arrives, which
        // is indistinguishable from the bug this scenario exists to fix.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let morning = calendar.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 6))!
        XCTAssertEqual(
            calendar.component(.day, from: WeeklyRecapScheduler.nextDeliveryDate(after: morning, calendar: calendar)),
            7,
            "before the delivery hour, today still works"
        )

        let evening = calendar.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 22))!
        XCTAssertEqual(
            calendar.component(.day, from: WeeklyRecapScheduler.nextDeliveryDate(after: evening, calendar: calendar)),
            8,
            "after it, the next day — never a trigger in the past"
        )

        let exactly = calendar.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: WeeklyRecapScheduler.deliveryHour))!
        XCTAssertEqual(
            calendar.component(.day, from: WeeklyRecapScheduler.nextDeliveryDate(after: exactly, calendar: calendar)),
            8,
            "on the hour is already too late: the minute has passed"
        )
    }

    func testTheLedgerRoundTripsThroughTheBudgetsRules() {
        let defaults = UserDefaults(suiteName: "WeeklyRecapNoticeTests.\(UUID().uuidString)")!
        let ledger = ProactiveLedger(defaults: defaults)
        XCTAssertNil(ledger.lastProactiveSentAtMillis)

        ledger.recordProactiveSent(at: 5_000)
        XCTAssertEqual(ledger.lastProactiveSentAtMillis, 5_000)

        // Never backwards — a device whose clock went back must not reopen the week.
        ledger.recordProactiveSent(at: 1_000)
        XCTAssertEqual(ledger.lastProactiveSentAtMillis, 5_000)

        ledger.recordRecapNotified(weekStartEpochDay: week)
        XCTAssertEqual(ledger.lastRecapWeekStartEpochDay, week)
    }
}
