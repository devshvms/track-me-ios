import XCTest
@testable import track_me_ios

/// SCOPE_1.8.7 §6.1.3 scenario 12a.
///
/// The tests that matter here are the ones asserting that nothing schedules itself. 12a is exempt
/// from the Class C budget because the user chose the cadence; if a reminder can ever exist without
/// a user action, that exemption becomes a way for the app to notify weekly outside the budget it
/// was written to obey.
final class ActivityReminderTests: XCTestCase {

    func testAReminderIsOffUntilSomeoneTurnsItOn() {
        XCTAssertFalse(ActivityReminder.Settings().enabled)
    }

    func testPrefillingFromASuggestionStillDoesNotEnableIt() {
        let suggestion = RideHistoryProfile.SuggestedSlot(
            dayOfWeek: 6, hour: 8, persona: "RUN", rideCount: 12
        )
        let prefilled = ActivityReminder.prefill(suggestion)

        XCTAssertFalse(
            prefilled.enabled,
            "a suggestion that arrives already enabled is scenario 12, which was cut"
        )
        XCTAssertEqual(prefilled.dayOfWeek, 6)
        XCTAssertEqual(prefilled.hour, 8)
        XCTAssertEqual(prefilled.persona, "RUN")
    }

    func testPrefillingWithNoSuggestionYieldsTheNeutralDefault() {
        let prefilled = ActivityReminder.prefill(nil)
        XCTAssertFalse(prefilled.enabled)
        XCTAssertEqual(prefilled.dayOfWeek, ActivityReminder.Settings.defaultDay)
        XCTAssertEqual(prefilled.hour, ActivityReminder.Settings.defaultHour)
    }

    func testADisabledReminderNeverFires() {
        XCTAssertFalse(ActivityReminder.shouldFire(
            settings: ActivityReminder.Settings(enabled: false, dayOfWeek: 6),
            nowDayOfWeek: 6, nowEpochDay: 100, lastFiredEpochDay: nil
        ))
    }

    func testAnEnabledReminderFiresOnItsDay() {
        XCTAssertTrue(ActivityReminder.shouldFire(
            settings: ActivityReminder.Settings(enabled: true, dayOfWeek: 6),
            nowDayOfWeek: 6, nowEpochDay: 100, lastFiredEpochDay: nil
        ))
    }

    func testItDoesNotFireOnAnyOtherDay() {
        for day in (1...7) where day != 6 {
            XCTAssertFalse(
                ActivityReminder.shouldFire(
                    settings: ActivityReminder.Settings(enabled: true, dayOfWeek: 6),
                    nowDayOfWeek: day, nowEpochDay: 100, lastFiredEpochDay: nil
                ),
                "fired on day \(day) for a Saturday reminder"
            )
        }
    }

    /// Both platforms' schedulers can wake more than once inside the firing window. Arriving twice
    /// on the same morning reads as a bug in a way that a missed one does not.
    func testItFiresOncePerDayEvenWhenTheSchedulerWakesTwice() {
        let settings = ActivityReminder.Settings(enabled: true, dayOfWeek: 6)
        XCTAssertTrue(ActivityReminder.shouldFire(
            settings: settings, nowDayOfWeek: 6, nowEpochDay: 100, lastFiredEpochDay: nil
        ))
        XCTAssertFalse(
            ActivityReminder.shouldFire(
                settings: settings, nowDayOfWeek: 6, nowEpochDay: 100, lastFiredEpochDay: 100
            ),
            "a second wake on the same day must not notify again"
        )
    }

    func testItFiresAgainTheFollowingWeek() {
        XCTAssertTrue(ActivityReminder.shouldFire(
            settings: ActivityReminder.Settings(enabled: true, dayOfWeek: 6),
            nowDayOfWeek: 6, nowEpochDay: 107, lastFiredEpochDay: 100
        ))
    }

    /// A restore from backup, or a timezone edit, can leave a last-fired stamp in the future.
    /// Treating that as "not yet fired" would emit a reminder on every wake until real time caught
    /// up — the same failure the proactive budget guards against.
    func testALastFiredStampInTheFutureSuppressesRatherThanRepeats() {
        XCTAssertFalse(ActivityReminder.shouldFire(
            settings: ActivityReminder.Settings(enabled: true, dayOfWeek: 6),
            nowDayOfWeek: 6, nowEpochDay: 100, lastFiredEpochDay: 500
        ))
    }

    func testAnInvalidSlotNeverFires() {
        let invalid = [
            ActivityReminder.Settings(enabled: true, dayOfWeek: 0),
            ActivityReminder.Settings(enabled: true, dayOfWeek: 8),
            ActivityReminder.Settings(enabled: true, dayOfWeek: 6, hour: 24),
            ActivityReminder.Settings(enabled: true, dayOfWeek: 6, minute: 60),
        ]
        for settings in invalid {
            XCTAssertFalse(
                ActivityReminder.shouldFire(
                    settings: settings, nowDayOfWeek: 6, nowEpochDay: 100, lastFiredEpochDay: nil
                ),
                "invalid settings fired: \(settings)"
            )
        }
    }
}

/// SCOPE_1.8.7 §6.1.4 scenario 22 — the trust sibling of §6.1.1 #6.
final class GroupPresenceNoticeTests: XCTestCase {

    func testALiveGroupAfterTheRideEndedIsWorthSaying() {
        XCTAssertTrue(GroupPresenceNotice.shouldNotify(
            activeGroupId: "g1", isGroupLive: true, isRideActive: false, alreadyNoticedGroupIds: []
        ))
    }

    func testNoGroupMeansNothingToSay() {
        XCTAssertFalse(GroupPresenceNotice.shouldNotify(
            activeGroupId: nil, isGroupLive: true, isRideActive: false, alreadyNoticedGroupIds: []
        ))
    }

    func testABlankGroupIdIsNotAGroup() {
        XCTAssertFalse(GroupPresenceNotice.shouldNotify(
            activeGroupId: "   ", isGroupLive: true, isRideActive: false, alreadyNoticedGroupIds: []
        ))
    }

    /// An expired group shares nothing, so warning about it raises an alarm about a passed risk.
    func testAnEndedGroupIsNotADisclosure() {
        XCTAssertFalse(GroupPresenceNotice.shouldNotify(
            activeGroupId: "g1", isGroupLive: false, isRideActive: false, alreadyNoticedGroupIds: []
        ))
    }

    /// During a ride, group presence is the point, and the live activity already says so.
    func testItStaysQuietWhileARideIsRunning() {
        XCTAssertFalse(GroupPresenceNotice.shouldNotify(
            activeGroupId: "g1", isGroupLive: true, isRideActive: true, alreadyNoticedGroupIds: []
        ))
    }

    /// Once per group, ever. A rider told about group X who chose to stay has answered; asking
    /// again after their next ride is the app arguing with a decision it prompted.
    func testItAsksAboutAGivenGroupOnlyOnce() {
        XCTAssertFalse(GroupPresenceNotice.shouldNotify(
            activeGroupId: "g1", isGroupLive: true, isRideActive: false, alreadyNoticedGroupIds: ["g1"]
        ))
    }

    func testADifferentGroupIsADifferentDisclosure() {
        XCTAssertTrue(GroupPresenceNotice.shouldNotify(
            activeGroupId: "g2", isGroupLive: true, isRideActive: false, alreadyNoticedGroupIds: ["g1"]
        ))
    }
}

/// SCOPE_1.8.7 §6.1.1 scenario 4.
final class ForgottenRideNoticeTests: XCTestCase {

    func testItAsksAfterFortyFiveStillMinutes() {
        XCTAssertTrue(ForgottenRideNotice.shouldAsk(
            stillnessSeconds: 45 * 60, alreadyAsked: false, isTracking: true
        ))
    }

    func testItStaysQuietBeforeTheThreshold() {
        XCTAssertFalse(ForgottenRideNotice.shouldAsk(
            stillnessSeconds: 45 * 60 - 1, alreadyAsked: false, isTracking: true
        ))
    }

    /// Someone who has decided to keep recording while stationary has answered.
    func testItAsksOnlyOncePerRide() {
        XCTAssertFalse(ForgottenRideNotice.shouldAsk(
            stillnessSeconds: 10 * 60 * 60, alreadyAsked: true, isTracking: true
        ))
    }

    /// A ride the user paused deliberately is not a forgotten ride.
    func testAPausedRideIsNotAForgottenRide() {
        XCTAssertFalse(ForgottenRideNotice.shouldAsk(
            stillnessSeconds: 10 * 60 * 60, alreadyAsked: false, isTracking: false
        ))
    }

    /// Both platforms must agree on the threshold, or one nags an hour before the other.
    func testTheThresholdMatchesTheAndroidConstant() {
        XCTAssertEqual(ForgottenRideNotice.stillnessBeforeNoticeSeconds, 45 * 60)
    }
}

/// The weekday conversion, which is the one place a plausible-looking wrong answer can be produced.
///
/// `Calendar`'s weekday is 1 for Sunday and the vectors are ISO-8601, where Sunday is 7. An
/// unconverted value shifts every suggestion by a day and offers a Saturday rider "Friday" — which
/// reads as a real suggestion rather than as a bug, and so would survive a manual look.
final class RideHistoryProfileSourceTests: XCTestCase {

    func testFoundationWeekdaysConvertToISOWeekdays() {
        XCTAssertEqual(RideHistoryProfileSource.isoDayOfWeek(1), 7)  // Sunday
        XCTAssertEqual(RideHistoryProfileSource.isoDayOfWeek(2), 1)  // Monday
        XCTAssertEqual(RideHistoryProfileSource.isoDayOfWeek(3), 2)
        XCTAssertEqual(RideHistoryProfileSource.isoDayOfWeek(4), 3)
        XCTAssertEqual(RideHistoryProfileSource.isoDayOfWeek(5), 4)
        XCTAssertEqual(RideHistoryProfileSource.isoDayOfWeek(6), 5)
        XCTAssertEqual(RideHistoryProfileSource.isoDayOfWeek(7), 6)  // Saturday
    }

    func testTheConversionRoundTrips() {
        for iso in 1...7 {
            XCTAssertEqual(
                RideHistoryProfileSource.isoDayOfWeek(RideHistoryProfileSource.foundationWeekday(iso)),
                iso
            )
        }
    }

    func testASaturdayMorningRideBecomesISODay6() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))

        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 5 // a Saturday
        components.hour = 8
        components.minute = 30
        let date = try XCTUnwrap(calendar.date(from: components))

        let parts = calendar.dateComponents([.weekday, .hour], from: date)
        XCTAssertEqual(RideHistoryProfileSource.isoDayOfWeek(try XCTUnwrap(parts.weekday)), 6)
        XCTAssertEqual(parts.hour, 8)
    }

    /// The same instant is a different weekday either side of the date line. Bucketing in the
    /// device's current zone is the deliberate choice — a rider who has moved wants a reminder in
    /// the mornings they are now living — and this pins that it is actually happening.
    func testRidesAreBucketedInTheSuppliedTimezoneNotUTC() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))

        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 5
        components.hour = 23
        components.minute = 30
        let instant = try XCTUnwrap(utc.date(from: components))

        var auckland = Calendar(identifier: .gregorian)
        auckland.timeZone = try XCTUnwrap(TimeZone(identifier: "Pacific/Auckland"))

        XCTAssertEqual(
            RideHistoryProfileSource.isoDayOfWeek(
                try XCTUnwrap(utc.dateComponents([.weekday], from: instant).weekday)
            ),
            6
        )
        XCTAssertEqual(
            RideHistoryProfileSource.isoDayOfWeek(
                try XCTUnwrap(auckland.dateComponents([.weekday], from: instant).weekday)
            ),
            7
        )
    }
}
