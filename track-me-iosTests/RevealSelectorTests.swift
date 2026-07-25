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
            streakAdvanced: true,
            streakFroze: false
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

    // MARK: - RevealCoordinator Persistence Tests (TASK-054)

    private var defaults: UserDefaults { .standard }
    private let testKey = "pending_reveal_v1"

    private func makeReveal(rideId: String = "ride-1") -> Reveal {
        Reveal(
            rideId: rideId,
            kind: .standard,
            totalRides: 5,
            distanceMeters: 3200,
            durationMillis: 900_000,
            milestoneRideCount: nil
        )
    }

    @MainActor
    func testSwipeDismiss_thenReacknowledge_clearsPersistedOneShot() {
        defaults.removeObject(forKey: testKey)
        defer { defaults.removeObject(forKey: testKey) }

        let coordinator = RevealCoordinator.shared
        coordinator.put(makeReveal())

        XCTAssertNotNil(defaults.data(forKey: testKey))

        // Simulate SwiftUI's swipe-dismiss binding write: memory-only, does NOT call consume().
        coordinator.pending = nil

        // The sheet's onDismiss handler.
        coordinator.acknowledgeDisplayed()

        // Disk key must be removed so cold launch does not re-seed it.
        XCTAssertNil(defaults.data(forKey: testKey),
                     "After acknowledgment the persisted key must be removed from disk.")
    }

    @MainActor
    func testButtonDismiss_clearsPersistedOneShot() {
        defaults.removeObject(forKey: testKey)
        defer { defaults.removeObject(forKey: testKey) }

        let coordinator = RevealCoordinator.shared
        let reveal = makeReveal()
        coordinator.put(reveal)

        coordinator.consume(rideId: reveal.rideId)

        XCTAssertNil(coordinator.pending)
        XCTAssertNil(defaults.data(forKey: testKey))
    }

    @MainActor
    func testConsume_wrongRideId_isNoOp() {
        defaults.removeObject(forKey: testKey)
        defer { defaults.removeObject(forKey: testKey) }

        let coordinator = RevealCoordinator.shared
        coordinator.put(makeReveal(rideId: "newer"))

        coordinator.consume(rideId: "older-already-gone")

        XCTAssertNotNil(coordinator.pending)
        XCTAssertNotNil(defaults.data(forKey: testKey))
    }

    @MainActor
    func testDurableOneShot_survivesProcessDeathBeforeShow() {
        defaults.removeObject(forKey: testKey)
        defer { defaults.removeObject(forKey: testKey) }

        let coordinator = RevealCoordinator.shared
        coordinator.put(makeReveal(rideId: "persisted-before-show"))

        guard let data = defaults.data(forKey: testKey),
              let decoded = try? JSONDecoder().decode(Reveal.self, from: data) else {
            XCTFail("Persisted data should be non-nil and decodable")
            return
        }

        XCTAssertEqual(decoded.rideId, "persisted-before-show")
    }

    @MainActor
    func testAcknowledge_isIdempotent() {
        defaults.removeObject(forKey: testKey)
        defer { defaults.removeObject(forKey: testKey) }

        let coordinator = RevealCoordinator.shared
        coordinator.put(makeReveal())

        coordinator.acknowledgeDisplayed()
        coordinator.acknowledgeDisplayed()

        XCTAssertNil(coordinator.pending)
        XCTAssertNil(defaults.data(forKey: testKey))
    }
}
