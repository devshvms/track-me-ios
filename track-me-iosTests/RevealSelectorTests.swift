import XCTest
@testable import track_me_ios

/// Unit tests for the pure B1 `RevealSelector` (iOS). Mirrors the Android `RevealSelectorTest`:
/// bounded set, strict priority (first ride → distance PR → duration PR → milestone → default),
/// taxonomy mapping, and idempotent-replay → nil.
final class RevealSelectorTests: XCTestCase {

    private func transition(
        rideId: String = "1",
        alreadyProcessed: Bool = false,
        isFirstRide: Bool = false,
        isDistancePR: Bool = false,
        isDurationPR: Bool = false,
        milestoneRideCount: Int? = nil,
        totalRides: Int = 5,
        distanceMeters: Double = 3200.0,
        durationMillis: Int64 = 900_000
    ) -> RideStatsTransition {
        RideStatsTransition(
            rideId: rideId,
            alreadyProcessed: alreadyProcessed,
            isFirstRide: isFirstRide,
            isDistancePR: isDistancePR,
            isDurationPR: isDurationPR,
            milestoneRideCount: milestoneRideCount,
            totalRides: totalRides,
            distanceMeters: distanceMeters,
            durationMillis: durationMillis,
            weekKey: "2026-W30",
            weekRideCount: 1,
            weekDistanceMeters: distanceMeters,
            streakWeeks: 1,
            isFirstRideOfWeek: true,
            streakAdvanced: true
        )
    }

    func testAlreadyProcessed_selectsNothing() {
        XCTAssertNil(RevealSelector.select(transition(alreadyProcessed: true)))
    }

    func testFirstRide_wins_overPrAndMilestone() {
        let r = RevealSelector.select(transition(isFirstRide: true, isDistancePR: true, milestoneRideCount: 10))!
        XCTAssertEqual(r.kind, .firstRide)
        XCTAssertEqual(r.revealType, "first_ride")
    }

    func testDistancePr_beats_durationPr_and_milestone() {
        let r = RevealSelector.select(transition(isDistancePR: true, isDurationPR: true, milestoneRideCount: 25))!
        XCTAssertEqual(r.kind, .distancePR)
        XCTAssertEqual(r.revealType, "pr")
    }

    func testDurationPr_beats_milestone() {
        let r = RevealSelector.select(transition(isDurationPR: true, milestoneRideCount: 50))!
        XCTAssertEqual(r.kind, .durationPR)
        XCTAssertEqual(r.revealType, "pr")
    }

    func testMilestone_whenNoPr() {
        let r = RevealSelector.select(transition(milestoneRideCount: 100, totalRides: 100))!
        XCTAssertEqual(r.kind, .milestone)
        XCTAssertEqual(r.revealType, "milestone")
        XCTAssertEqual(r.milestoneRideCount, 100)
    }

    func testOrdinaryGoodRide_getsDefault_notNil() {
        let r = RevealSelector.select(transition())!
        XCTAssertEqual(r.kind, .standard)
        XCTAssertEqual(r.revealType, "default")
    }

    func testReveal_isCodable_roundTrips() throws {
        let r = RevealSelector.select(transition(rideId: "42", distanceMeters: 5000, durationMillis: 1_800_000))!
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(Reveal.self, from: data)
        XCTAssertEqual(r, back)
    }
}
