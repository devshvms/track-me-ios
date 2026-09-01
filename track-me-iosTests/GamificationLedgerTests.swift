import XCTest
@testable import track_me_ios

/// TASK-276: the achieved-on date and persona split are derived, so they must track the rides.
/// Mirrors the Android suite case for case.
final class GamificationLedgerTests: XCTestCase {

    private func at(_ iso: String) -> Int64 {
        let formatter = ISO8601DateFormatter()
        return Int64(formatter.date(from: iso)!.timeIntervalSince1970 * 1000)
    }

    private func ride(_ iso: String, _ persona: String, minutes: Int64,
                      metres: Double = 1_000) -> GamificationLedger.RideFact {
        GamificationLedger.RideFact(
            atEpochMillis: at(iso),
            personaRaw: persona,
            activeDurationMillis: minutes * 60_000,
            distanceMeters: metres
        )
    }

    private func ledger(_ rides: GamificationLedger.RideFact...) -> [String: GamificationLedger.LevelAchievement] {
        Dictionary(uniqueKeysWithValues: GamificationLedger.derive(rides).map { ($0.levelId, $0) })
    }

    func testNoRidesMeansNothingIsAchieved() {
        let l = ledger()
        XCTAssertNil(l["level_1"]?.achievedAtEpochMillis)
        XCTAssertNil(l["level_2"]?.achievedAtEpochMillis)
        XCTAssertEqual(l["level_1"]?.personaSplit.count, 0)
    }

    func testLevelOneIsTheFirstRideNotAThresholdCrossing() {
        // Its threshold is zero, so "reached at 0 minutes" would be true before doing anything.
        let l = ledger(
            ride("2026-06-02T07:00:00Z", "CYCLING", minutes: 30),
            ride("2026-06-09T07:00:00Z", "CYCLING", minutes: 30)
        )
        XCTAssertEqual(l["level_1"]?.achievedAtEpochMillis, at("2026-06-02T07:00:00Z"))
    }

    func testALevelIsDatedByTheRideThatCrossedIt() {
        // level_2 needs 120 minutes; the third ride is the one that gets there.
        let l = ledger(
            ride("2026-06-02T07:00:00Z", "CYCLING", minutes: 50),
            ride("2026-06-09T07:00:00Z", "CYCLING", minutes: 50),
            ride("2026-06-16T07:00:00Z", "WALKING", minutes: 30),
            ride("2026-06-23T07:00:00Z", "CYCLING", minutes: 40)
        )
        XCTAssertEqual(l["level_2"]?.achievedAtEpochMillis, at("2026-06-16T07:00:00Z"))
    }

    func testTheSplitCoversEverythingUpToTheCrossingAndNoFurther() {
        let l = ledger(
            ride("2026-06-02T07:00:00Z", "CYCLING", minutes: 50, metres: 12_000),
            ride("2026-06-09T07:00:00Z", "CYCLING", minutes: 50, metres: 11_000),
            ride("2026-06-16T07:00:00Z", "WALKING", minutes: 30, metres: 2_500),
            // after the crossing — must not appear in level_2's split
            ride("2026-06-23T07:00:00Z", "CYCLING", minutes: 40, metres: 9_000)
        )
        let split = l["level_2"]!.personaSplit
        XCTAssertEqual(split.count, 2)
        XCTAssertEqual(split[0].personaRaw, "CYCLING")
        XCTAssertEqual(split[0].activeDurationMillis, 100 * 60_000)
        XCTAssertEqual(split[0].distanceMeters, 23_000, accuracy: 0.001)
        XCTAssertEqual(split[1].personaRaw, "WALKING")
    }

    func testAnEarlierLevelKeepsItsAnswerWhenALaterOneIsReached() {
        let l = ledger(
            ride("2026-06-02T07:00:00Z", "CYCLING", minutes: 130),
            ride("2026-07-02T07:00:00Z", "CYCLING", minutes: 500)
        )
        XCTAssertEqual(l["level_2"]?.achievedAtEpochMillis, at("2026-06-02T07:00:00Z"))
        XCTAssertEqual(l["level_2"]?.personaSplit.first?.activeDurationMillis, 130 * 60_000)
        XCTAssertEqual(l["level_3"]?.achievedAtEpochMillis, at("2026-07-02T07:00:00Z"))
        XCTAssertEqual(l["level_3"]?.personaSplit.first?.activeDurationMillis, 630 * 60_000)
    }

    func testAnUnreachedLevelHasNoDateAndNoSplit() {
        let l = ledger(ride("2026-06-02T07:00:00Z", "CYCLING", minutes: 130))
        XCTAssertNil(l["level_3"]?.achievedAtEpochMillis)
        XCTAssertEqual(l["level_3"]?.personaSplit.count, 0)
    }

    func testOutOfOrderInputDoesNotChangeTheAnswer() {
        let forwards = ledger(
            ride("2026-06-02T07:00:00Z", "CYCLING", minutes: 50),
            ride("2026-06-09T07:00:00Z", "CYCLING", minutes: 50),
            ride("2026-06-16T07:00:00Z", "WALKING", minutes: 30)
        )
        let backwards = ledger(
            ride("2026-06-16T07:00:00Z", "WALKING", minutes: 30),
            ride("2026-06-09T07:00:00Z", "CYCLING", minutes: 50),
            ride("2026-06-02T07:00:00Z", "CYCLING", minutes: 50)
        )
        XCTAssertEqual(forwards["level_2"]?.achievedAtEpochMillis,
                       backwards["level_2"]?.achievedAtEpochMillis)
    }

    func testMinutesRoundOnceMatchingTheEngineRatherThanDriftingBelowIt() {
        // Three rides of 40.5 minutes are 121 together, which reaches level_2. Rounding each ride
        // down first would give 120 and land on the threshold by luck rather than arithmetic.
        let rides = (0..<3).map { index in
            GamificationLedger.RideFact(
                atEpochMillis: at("2026-06-0\(index + 1)T07:00:00Z"),
                personaRaw: "CYCLING",
                activeDurationMillis: 40 * 60_000 + 30_000,
                distanceMeters: 1_000
            )
        }
        XCTAssertEqual(rides.reduce(Int64(0)) { $0 + $1.activeDurationMillis } / 60_000, 121)
        let l = Dictionary(uniqueKeysWithValues: GamificationLedger.derive(rides).map { ($0.levelId, $0) })
        XCTAssertEqual(l["level_2"]?.achievedAtEpochMillis, at("2026-06-03T07:00:00Z"))
    }

    func testTiesBetweenPersonasOrderStably() {
        let l = ledger(
            ride("2026-06-02T07:00:00Z", "WALKING", minutes: 60),
            ride("2026-06-03T07:00:00Z", "CYCLING", minutes: 60)
        )
        XCTAssertEqual(l["level_2"]?.personaSplit.map(\.personaRaw), ["CYCLING", "WALKING"])
    }
}
