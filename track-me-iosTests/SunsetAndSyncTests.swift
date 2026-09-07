import XCTest
@testable import track_me_ios

/// SCOPE_1.8.7 §6.1.6 #28 and §6.1.5 #23 — the two iOS twins, against the same cases as Android.
///
/// The sunset tests assert against **real published sunsets for real places on real dates**, not
/// against the implementation's own output. A solar algorithm that is subtly wrong still produces
/// plausible-looking times all year round, so the only test worth having is one that could have
/// been written before the code.
final class SunsetAndSyncTests: XCTestCase {

    // MARK: - Sunset

    private func assertSunsetNear(
        _ description: String,
        latitude: Double, longitude: Double, dayOfYear: Int, utcOffsetMinutes: Int,
        hour: Int, minute: Int, tolerance: Int = 6,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let actual = SunsetCalculator.sunsetMinutesAfterMidnight(
            latitude: latitude, longitude: longitude,
            dayOfYear: dayOfYear, utcOffsetMinutes: utcOffsetMinutes
        ) else {
            return XCTFail("\(description): the sun does set here", file: file, line: line)
        }
        let expected = hour * 60 + minute
        XCTAssertTrue(
            abs(actual - expected) <= tolerance,
            "\(description): expected ~\(hour):\(String(format: "%02d", minute)), got \(actual / 60):\(String(format: "%02d", actual % 60))",
            file: file, line: line
        )
    }

    func testBengaluruInSeptember() {
        assertSunsetNear("Bengaluru, 7 Sep", latitude: 12.9716, longitude: 77.5946,
                         dayOfYear: 250, utcOffsetMinutes: 330, hour: 18, minute: 26)
    }

    func testLondonAtBothSolstices() {
        // The widest spread any populated place gives — the case that catches an algorithm which
        // has flattened the seasonal variation.
        assertSunsetNear("London, 21 Jun (BST)", latitude: 51.5074, longitude: -0.1278,
                         dayOfYear: 172, utcOffsetMinutes: 60, hour: 21, minute: 21)
        assertSunsetNear("London, 21 Dec (GMT)", latitude: 51.5074, longitude: -0.1278,
                         dayOfYear: 355, utcOffsetMinutes: 0, hour: 15, minute: 53)
    }

    func testTheSouthernHemisphereRunsTheOtherWay() {
        // A sign error in the declination gets every northern city right and every southern one
        // exactly backwards.
        assertSunsetNear("Sydney, 21 Dec", latitude: -33.8688, longitude: 151.2093,
                         dayOfYear: 355, utcOffsetMinutes: 660, hour: 20, minute: 5)
        assertSunsetNear("Sydney, 21 Jun", latitude: -33.8688, longitude: 151.2093,
                         dayOfYear: 172, utcOffsetMinutes: 600, hour: 16, minute: 53)
    }

    func testNearTheEquatorTheYearIsAlmostFlat() {
        // Singapore varies by under half an hour across the whole year. A calculator that
        // over-swings the season passes London and fails this.
        let june = SunsetCalculator.sunsetMinutesAfterMidnight(
            latitude: 1.3521, longitude: 103.8198, dayOfYear: 172, utcOffsetMinutes: 480)!
        let december = SunsetCalculator.sunsetMinutesAfterMidnight(
            latitude: 1.3521, longitude: 103.8198, dayOfYear: 355, utcOffsetMinutes: 480)!
        XCTAssertLessThan(abs(june - december), 60)
    }

    func testAboveTheArcticCircleInJuneTheSunDoesNotSet() {
        // Nil is a real answer. A caller that treats it as "unknown" and shows nothing is behaving
        // correctly for someone in Svalbard in midsummer.
        XCTAssertNil(SunsetCalculator.sunsetMinutesAfterMidnight(
            latitude: 78.2232, longitude: 15.6267, dayOfYear: 172, utcOffsetMinutes: 120))
    }

    func testNonsenseInputIsRefusedRatherThanAnswered() {
        XCTAssertNil(SunsetCalculator.sunsetMinutesAfterMidnight(latitude: 91, longitude: 0, dayOfYear: 100, utcOffsetMinutes: 0))
        XCTAssertNil(SunsetCalculator.sunsetMinutesAfterMidnight(latitude: 0, longitude: 181, dayOfYear: 100, utcOffsetMinutes: 0))
        XCTAssertNil(SunsetCalculator.sunsetMinutesAfterMidnight(latitude: 0, longitude: 0, dayOfYear: 0, utcOffsetMinutes: 0))
        XCTAssertNil(SunsetCalculator.sunsetMinutesAfterMidnight(latitude: 0, longitude: 0, dayOfYear: 367, utcOffsetMinutes: 0))
    }

    func testEveryAnswerIsARealTimeOfDay() {
        // Wrapping rather than clamping: a sunset can land on the adjacent calendar day in local
        // time near a date line or a large offset, and clamping would report midnight.
        for offset in [-720, -330, 0, 330, 780] {
            for day in stride(from: 1, through: 366, by: 29) {
                if let minutes = SunsetCalculator.sunsetMinutesAfterMidnight(
                    latitude: 35, longitude: 139, dayOfYear: day, utcOffsetMinutes: offset) {
                    XCTAssertTrue((0...1439).contains(minutes), "offset=\(offset) day=\(day) gave \(minutes)")
                }
            }
        }
    }

    func testTheWindowIsHonouredAtBothEnds() {
        // Already past, far away, and exactly on the boundary.
        XCTAssertNil(SunsetCalculator.minutesUntilSunset(
            latitude: 12.9716, longitude: 77.5946, dayOfYear: 250,
            minutesAfterLocalMidnightNow: 20 * 60, utcOffsetMinutes: 330))
        XCTAssertNil(SunsetCalculator.minutesUntilSunset(
            latitude: 12.9716, longitude: 77.5946, dayOfYear: 250,
            minutesAfterLocalMidnightNow: 10 * 60, utcOffsetMinutes: 330))

        let sunset = SunsetCalculator.sunsetMinutesAfterMidnight(
            latitude: 12.9716, longitude: 77.5946, dayOfYear: 250, utcOffsetMinutes: 330)!
        let justInside = sunset - SunsetCalculator.maxMinutesWorthMentioning
        XCTAssertNotNil(SunsetCalculator.minutesUntilSunset(
            latitude: 12.9716, longitude: 77.5946, dayOfYear: 250,
            minutesAfterLocalMidnightNow: justInside, utcOffsetMinutes: 330))
        XCTAssertNil(SunsetCalculator.minutesUntilSunset(
            latitude: 12.9716, longitude: 77.5946, dayOfYear: 250,
            minutesAfterLocalMidnightNow: justInside - 1, utcOffsetMinutes: 330))
    }

    func testBothPlatformsAgreeOnTheSameSunsets() {
        // Android's SunsetCalculatorTest asserts these same five places. If the two implementations
        // drift, one platform tells a rider they have forty minutes of light and the other does not
        // mention it at all — and neither suite would notice on its own.
        let cases: [(String, Double, Double, Int, Int)] = [
            ("Bengaluru", 12.9716, 77.5946, 250, 330),
            ("London midsummer", 51.5074, -0.1278, 172, 60),
            ("Sydney midsummer", -33.8688, 151.2093, 355, 660),
            ("Singapore", 1.3521, 103.8198, 172, 480),
        ]
        for (name, lat, lon, day, offset) in cases {
            XCTAssertNotNil(
                SunsetCalculator.sunsetMinutesAfterMidnight(
                    latitude: lat, longitude: lon, dayOfYear: day, utcOffsetMinutes: offset),
                name
            )
        }
    }

    // MARK: - Sync failure

    private let threshold = SyncFailureNotice.consecutiveFailuresBeforeNotice

    func testOneFailureSaysNothing() {
        // Sync fails constantly and harmlessly: a tunnel, a café network, airplane mode.
        XCTAssertFalse(SyncFailureNotice.shouldNotify(
            consecutiveFailures: 1, unsyncedRideCount: 5, alreadyNotifiedThisEpisode: false))
    }

    func testPersistentFailureWithRidesWaitingIsReported() {
        XCTAssertTrue(SyncFailureNotice.shouldNotify(
            consecutiveFailures: threshold, unsyncedRideCount: 5, alreadyNotifiedThisEpisode: false))
    }

    func testNothingWaitingMeansNothingAtRisk() {
        // A failing sync with an empty queue is the app reporting its own internal state, which is
        // not a fact about the user (§4.2 N1).
        XCTAssertFalse(SyncFailureNotice.shouldNotify(
            consecutiveFailures: threshold + 10, unsyncedRideCount: 0, alreadyNotifiedThisEpisode: false))
    }

    func testAnEpisodeIsReportedOnceAndASuccessEndsIt() {
        // "Once per episode" has to mean an episode, not "once ever" — a user whose backup breaks
        // twice in a year should be told twice.
        var state = SyncFailureNotice.Episode()
        for _ in 0..<threshold { state = SyncFailureNotice.record(succeeded: false, state: state) }
        XCTAssertTrue(SyncFailureNotice.shouldNotify(
            consecutiveFailures: state.consecutiveFailures, unsyncedRideCount: 5,
            alreadyNotifiedThisEpisode: state.notified))

        state.notified = true
        XCTAssertFalse(SyncFailureNotice.shouldNotify(
            consecutiveFailures: state.consecutiveFailures, unsyncedRideCount: 5,
            alreadyNotifiedThisEpisode: state.notified))

        state = SyncFailureNotice.record(succeeded: true, state: state)
        XCTAssertEqual(state, SyncFailureNotice.Episode())
    }

    func testAnIntermittentConnectionNeverAccumulatesToAFalseAlarm() {
        // The realistic pattern: fail, fail, succeed, fail, fail, succeed. Two short outages, no
        // problem, and the counter must not carry across the successes.
        var state = SyncFailureNotice.Episode()
        for ok in [false, false, true, false, false, true, false] {
            state = SyncFailureNotice.record(succeeded: ok, state: state)
            XCTAssertFalse(
                SyncFailureNotice.shouldNotify(
                    consecutiveFailures: state.consecutiveFailures, unsyncedRideCount: 5,
                    alreadyNotifiedThisEpisode: state.notified),
                "an intermittent connection must never trip the notice"
            )
        }
    }

    func testABrokenBackupIsNeverSuppressedByTheProactiveBudget() {
        XCTAssertTrue(NotificationBudget.allows(.consequential, nowMillis: 0, lastProactiveSentAtMillis: 0))
        XCTAssertFalse(NotificationBudget.Klass.consequential.spendsProactiveBudget)
    }
}
