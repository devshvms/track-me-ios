import XCTest
@testable import track_me_ios

/// TASK-119 regression coverage for `CalmMomentGate` — the pure "is now a calm moment to show a
/// non-urgent celebration" decision behind the B2 weekly recap. Mirrors Android
/// `CalmMomentGateTest.kt` case for case.
///
/// Prompt 09 ("Trigger") forbids the recap during an active/paused ride or a GPS-lost/storage-low
/// state. Before this task `WeeklyRecapCoordinator.check()` only checked for a pending B1 reveal,
/// so every other non-idle state let it through.
///
/// The gate is a plain value type with no actor isolation, so these tests need no `@MainActor`.
final class CalmMomentGateTests: XCTestCase {

    private func moment(
        isTrackingIdle: Bool = true,
        hasPendingReveal: Bool = false
    ) -> CalmMomentGate.AppMoment {
        CalmMomentGate.AppMoment(
            isTrackingIdle: isTrackingIdle,
            hasPendingReveal: hasPendingReveal
        )
    }

    func testIdleWithNothingPendingIsCalm() {
        XCTAssertTrue(CalmMomentGate.isCalm(moment()))
    }

    func testDefaultsDescribeTheCalmHappyPath() {
        XCTAssertTrue(CalmMomentGate.isCalm(CalmMomentGate.AppMoment()))
    }

    func testNonIdleTrackingStateIsNeverCalm() {
        // Covers .tracking, .paused, .gpsLost and .storageLow: the gate takes the already-mapped
        // boolean, so every non-.idle state collapses to this single case.
        XCTAssertFalse(CalmMomentGate.isCalm(moment(isTrackingIdle: false)))
    }

    func testPendingPostRideRevealIsNeverCalm() {
        XCTAssertFalse(CalmMomentGate.isCalm(moment(hasPendingReveal: true)))
    }

    func testEveryConditionIsIndependentlyBlocking() {
        XCTAssertFalse(CalmMomentGate.isCalm(moment(isTrackingIdle: false, hasPendingReveal: true)))
        XCTAssertFalse(CalmMomentGate.isCalm(moment(isTrackingIdle: false)))
        XCTAssertFalse(CalmMomentGate.isCalm(moment(hasPendingReveal: true)))
    }
}
