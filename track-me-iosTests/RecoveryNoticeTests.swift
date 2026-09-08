import XCTest
@testable import track_me_ios

/// SCOPE_1.8.7 §6.1.1 scenario 1 — the notification the app currently fails to send.
///
/// The PRD marks "the user is told when a ride was auto-finalized" as a failing criterion. Today
/// the recovery happens silently, so someone whose phone died mid-ride opens the app expecting to
/// have lost it. Case for case with Android's `RecoveryNoticeTest`.
final class RecoveryNoticeTests: XCTestCase {

    func testNothingRecoveredSaysNothing() {
        XCTAssertNil(RecoveryNotice.decide(
            recoveredCount: 0, discardedCount: 0, endedAtLabel: "14:32", distanceLabel: "12.3 km"
        ))
    }

    func testADiscardedEmptyRideIsNeverAnnounced() {
        // A discarded ride had no GPS points: nothing was recorded, so nothing was lost.
        // Announcing it would be the app narrating its own housekeeping — and would read as
        // "we deleted something of yours", the opposite of what this notification exists to say.
        XCTAssertNil(RecoveryNotice.decide(
            recoveredCount: 0, discardedCount: 3, endedAtLabel: "14:32", distanceLabel: "1 km"
        ))
    }

    func testOneRecoveredRideCarriesItsFacts() {
        XCTAssertEqual(
            RecoveryNotice.decide(recoveredCount: 1, discardedCount: 0, endedAtLabel: "14:32", distanceLabel: "12.3 km"),
            .one(endedAtLabel: "14:32", distanceLabel: "12.3 km")
        )
    }

    func testAMissingFactDropsBothRatherThanHalfASentence() {
        // "Recording stopped at ." is worse than the plain version. A recovered ride with one point
        // and no measurable distance is a real case, not a hypothetical.
        XCTAssertEqual(
            RecoveryNotice.decide(recoveredCount: 1, discardedCount: 0, endedAtLabel: "14:32", distanceLabel: nil),
            .one(endedAtLabel: nil, distanceLabel: nil)
        )
        XCTAssertEqual(
            RecoveryNotice.decide(recoveredCount: 1, discardedCount: 0, endedAtLabel: nil, distanceLabel: "12.3 km"),
            .one(endedAtLabel: nil, distanceLabel: nil)
        )
        XCTAssertEqual(
            RecoveryNotice.decide(recoveredCount: 1, discardedCount: 0, endedAtLabel: "  ", distanceLabel: "12.3 km"),
            .one(endedAtLabel: nil, distanceLabel: nil)
        )
    }

    func testSeveralRecoveredRidesReportTheCount() {
        // Naming a single end time when three rides were recovered would be actively misleading,
        // and listing all three is a notification nobody reads.
        XCTAssertEqual(
            RecoveryNotice.decide(recoveredCount: 3, discardedCount: 0, endedAtLabel: "14:32", distanceLabel: "12.3 km"),
            .many(count: 3)
        )
    }

    func testRecoveryIsNeverSuppressedByTheProactiveBudget() {
        // Class A, not Class C. Rationing this would mean a ride recovered in a week when a recap
        // already went out is a ride the user is never told about. Asserting the classification
        // here is what stops a future "unify everything through the budget" refactor from quietly
        // changing it.
        XCTAssertTrue(NotificationBudget.allows(.consequential, nowMillis: 0, lastProactiveSentAtMillis: 0))
        XCTAssertFalse(NotificationBudget.Klass.consequential.spendsProactiveBudget)
    }

    func testBothPlatformsAgreeOnEveryDecision() {
        // The table is the contract. Android's RecoveryNoticeTest asserts the same rows; a
        // divergence here means one platform tells people their ride was saved and the other
        // does not, which no single-platform suite would catch.
        let cases: [(Int, Int, String?, String?, RecoveryNotice?)] = [
            (0, 0, "14:32", "12.3 km", nil),
            (0, 5, "14:32", "12.3 km", nil),
            (1, 0, "14:32", "12.3 km", .one(endedAtLabel: "14:32", distanceLabel: "12.3 km")),
            (1, 2, "14:32", "12.3 km", .one(endedAtLabel: "14:32", distanceLabel: "12.3 km")),
            (1, 0, nil, nil, .one(endedAtLabel: nil, distanceLabel: nil)),
            (2, 0, "14:32", "12.3 km", .many(count: 2)),
            (9, 3, nil, nil, .many(count: 9)),
        ]
        for (recovered, discarded, endedAt, distance, expected) in cases {
            XCTAssertEqual(
                RecoveryNotice.decide(
                    recoveredCount: recovered, discardedCount: discarded,
                    endedAtLabel: endedAt, distanceLabel: distance
                ),
                expected,
                "recovered=\(recovered) discarded=\(discarded)"
            )
        }
    }
}
