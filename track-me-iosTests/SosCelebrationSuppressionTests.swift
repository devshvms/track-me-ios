import XCTest
@testable import track_me_ios

/// TASK-118 — iOS parity for the Android TASK-116 rule: a ride that entered the SOS flow is still
/// recorded in history and still counts toward aggregates, but it must NOT produce a B1 post-ride
/// reveal, and therefore must never chain into the B4 App Store review request.
///
/// Mirrors Android `RevealSelectorTest`, `RideStatsReducerTest` and `EmergencyManagerTest` for the
/// same change. Behaviour, thresholds and the (deliberately absent) telemetry match Android.
final class SosCelebrationSuppressionTests: XCTestCase {

    // MARK: - Helpers

    private func transition(
        alreadyProcessed: Bool = false,
        isFirstRide: Bool = false,
        isDistancePR: Bool = false,
        isDurationPR: Bool = false,
        milestoneRideCount: Int? = nil,
        suppressPostRideCelebrations: Bool = false
    ) -> RideStatsTransition {
        RideStatsTransition(
            rideId: "1",
            alreadyProcessed: alreadyProcessed,
            isFirstRide: isFirstRide,
            isDistancePR: isDistancePR,
            isDurationPR: isDurationPR,
            milestoneRideCount: milestoneRideCount,
            totalRides: 5,
            distanceMeters: 3200.0,
            durationMillis: 900_000,
            weekKey: "2026-W30",
            weekRideCount: 1,
            weekDistanceMeters: 3200.0,
            streakWeeks: 1,
            isFirstRideOfWeek: true,
            streakAdvanced: true,
            streakFroze: false,
            suppressPostRideCelebrations: suppressPostRideCelebrations
        )
    }

    private func makeManager(_ name: String = #function) -> (EmergencyManager, UserDefaults) {
        let suiteName = "SosCelebrationSuppressionTests.\(name)"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        return (EmergencyManager(defaults: defaults), defaults)
    }

    // MARK: - RevealSelector (pure decision)

    func testSuppressedRide_selectsNoReveal() {
        XCTAssertNil(RevealSelector.select(transition(suppressPostRideCelebrations: true)))
    }

    /// Suppression outranks every earned outcome, including the highest-priority one. A first ride
    /// that ended in an emergency must not be celebrated.
    func testSuppression_beats_everyRevealKind() {
        XCTAssertNil(RevealSelector.select(
            transition(isFirstRide: true, suppressPostRideCelebrations: true)))
        XCTAssertNil(RevealSelector.select(
            transition(isDistancePR: true, suppressPostRideCelebrations: true)))
        XCTAssertNil(RevealSelector.select(
            transition(isDurationPR: true, suppressPostRideCelebrations: true)))
        XCTAssertNil(RevealSelector.select(
            transition(milestoneRideCount: 100, suppressPostRideCelebrations: true)))
    }

    /// Regression guard: the new flag must not change the default (non-SOS) path.
    func testUnsuppressedOrdinaryRide_stillGetsDefaultReveal() {
        let r = RevealSelector.select(transition())
        XCTAssertEqual(r?.kind, .standard)
    }

    // MARK: - Reducer propagation (summary -> transition)

    func testReducer_propagatesSuppressionIntoTransition() {
        let summary = GoodRideSummary(
            rideId: "ride-sos",
            finishedAtMillis: 1_753_600_000_000,
            durationMillis: 900_000,
            distanceMeters: 3200.0,
            suppressPostRideCelebrations: true
        )
        let (stats, transition) = RideStatsReducer.reduce(
            RideStats(), summary, WeekKey.mondayAnchored(timeZone: TimeZone(identifier: "UTC")!))

        XCTAssertTrue(transition.suppressPostRideCelebrations)
        XCTAssertNil(RevealSelector.select(transition))
        // The ride is still fully counted — suppression is a presentation rule, not an exclusion.
        XCTAssertEqual(stats.totalRides, 1)
        XCTAssertEqual(stats.totalDistanceMeters, 3200.0)
        XCTAssertTrue(stats.processedRideIds.contains("ride-sos"))
    }

    /// The idempotent-replay branch builds its own transition; it must carry the flag too, so a
    /// re-delivered SOS ride cannot slip a reveal through the no-op path.
    func testReducer_propagatesSuppressionOnAlreadyProcessedReplay() {
        let calendar = WeekKey.mondayAnchored(timeZone: TimeZone(identifier: "UTC")!)
        let summary = GoodRideSummary(
            rideId: "ride-sos",
            finishedAtMillis: 1_753_600_000_000,
            durationMillis: 900_000,
            distanceMeters: 3200.0,
            suppressPostRideCelebrations: true
        )
        let (afterFirst, _) = RideStatsReducer.reduce(RideStats(), summary, calendar)
        let (_, replay) = RideStatsReducer.reduce(afterFirst, summary, calendar)

        XCTAssertTrue(replay.alreadyProcessed)
        XCTAssertTrue(replay.suppressPostRideCelebrations)
        XCTAssertNil(RevealSelector.select(replay))
    }

    func testReducer_defaultsToUnsuppressed_forExistingCallSites() {
        let summary = GoodRideSummary(
            rideId: "ride-normal",
            finishedAtMillis: 1_753_600_000_000,
            durationMillis: 900_000,
            distanceMeters: 3200.0
        )
        let (_, transition) = RideStatsReducer.reduce(
            RideStats(), summary, WeekKey.mondayAnchored(timeZone: TimeZone(identifier: "UTC")!))

        XCTAssertFalse(transition.suppressPostRideCelebrations)
        XCTAssertNotNil(RevealSelector.select(transition))
    }

    // MARK: - EmergencyManager per-ride suppression bit

    func testFreshRide_hasNoSuppression() {
        let (manager, _) = makeManager()
        manager.beginRideSession()
        XCTAssertFalse(manager.consumeRideSuppression())
    }

    func testTriggeringSos_suppressesTheRide() {
        let (manager, _) = makeManager()
        manager.beginRideSession()
        manager.startBroadcast()
        XCTAssertTrue(manager.consumeRideSuppression())
    }

    /// Resolving SOS mid-ride must NOT re-enable the celebration: the ride still had an emergency.
    /// Parity with Android, where `stopEmergency()` leaves the per-ride bit set.
    func testResolvingSosBeforeStoppingTheRide_stillSuppresses() {
        let (manager, _) = makeManager()
        manager.beginRideSession()
        manager.startBroadcast()
        manager.resolveBroadcast(falseAlarm: false)
        XCTAssertTrue(manager.consumeRideSuppression())
    }

    /// A cancelled composer is still "the user reached for SOS" — Android suppresses it, so iOS does.
    func testFalseAlarmSos_stillSuppresses() {
        let (manager, _) = makeManager()
        manager.beginRideSession()
        manager.startBroadcast()
        manager.resolveBroadcast(falseAlarm: true)
        XCTAssertTrue(manager.consumeRideSuppression())
    }

    /// One bit, one ride: the next ride starts clean.
    func testSuppression_isConsumedExactlyOnce() {
        let (manager, _) = makeManager()
        manager.beginRideSession()
        manager.startBroadcast()

        XCTAssertTrue(manager.consumeRideSuppression())
        XCTAssertFalse(manager.consumeRideSuppression())

        manager.beginRideSession()
        XCTAssertFalse(manager.consumeRideSuppression())
    }

    /// An SOS still in flight when the ride auto-splits must carry into Part 2, or the second
    /// segment earns a celebration during a live emergency.
    func testActiveSos_carriesAcrossARideSplit() {
        let (manager, _) = makeManager()
        manager.beginRideSession()
        manager.startBroadcast()

        // Part 1 finalizes...
        XCTAssertTrue(manager.consumeRideSuppression())
        // ...and Part 2 opens while the emergency is still unresolved.
        manager.beginRideSession()
        XCTAssertTrue(manager.consumeRideSuppression())
    }

    /// A resolved SOS must not leak into the next ride.
    func testResolvedSos_doesNotCarryIntoTheNextRide() {
        let (manager, _) = makeManager()
        manager.beginRideSession()
        manager.startBroadcast()
        manager.resolveBroadcast(falseAlarm: false)
        XCTAssertTrue(manager.consumeRideSuppression())

        manager.beginRideSession()
        XCTAssertFalse(manager.consumeRideSuppression())
    }

    /// The bit is persisted, so an SOS followed by an app kill before the ride is finalized still
    /// suppresses the reveal on the next launch. Parity with the Android SharedPreferences seam.
    func testSuppression_survivesProcessDeath() {
        let (manager, defaults) = makeManager()
        manager.beginRideSession()
        manager.startBroadcast()

        // Simulate relaunch: a brand-new instance over the same storage.
        let relaunched = EmergencyManager(defaults: defaults)
        XCTAssertTrue(relaunched.consumeRideSuppression())
    }

    func testConsumedSuppression_isClearedFromStorage() {
        let (manager, defaults) = makeManager()
        manager.beginRideSession()
        manager.startBroadcast()
        _ = manager.consumeRideSuppression()

        XCTAssertNil(defaults.object(forKey: "emergency_triggered_for_ride"),
                     "The consumed bit must be removed from storage, not left as false.")
    }
}
