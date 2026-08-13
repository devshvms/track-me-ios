import XCTest
@testable import track_me_ios

final class GroupPresencePolicyTests: XCTestCase {
    private let alert = RiderStatusCodec.parse("1GNH")!
    private let caution = RiderStatusCodec.parse("2GVI")!

    func testInactiveAndHealthyUnsetSessionsRenderNothing() {
        XCTAssertEqual(GroupPresencePolicy.evaluate(input(sessionActive: false)), .none)
        XCTAssertEqual(GroupPresencePolicy.evaluate(input()), .none)
    }

    func testPauseThresholdTracksCadenceWithoutOverlap() {
        XCTAssertEqual(GroupPresencePolicy.pauseThresholdMillis(syncIntervalSec: 10), 30_000)
        XCTAssertEqual(GroupPresencePolicy.pauseThresholdMillis(syncIntervalSec: 60), 120_000)
    }

    func testPausedUnsentAlertOutranksLastShared() {
        let pill = GroupPresencePolicy.evaluate(input(
            lastSuccessfulSyncElapsedMillis: 1_000,
            lastFailureKind: .noInternet,
            selfStatus: alert,
            selfStatusAcknowledged: false,
            nowElapsedMillis: 31_000
        ))
        XCTAssertEqual(
            pill,
            .pausedWithPendingStatus(
                cause: .local,
                rideRecording: true,
                status: alert,
                isClearing: false
            )
        )
    }

    func testPausedLowerTierAndClearRemainVisible() {
        XCTAssertEqual(
            GroupPresencePolicy.evaluate(input(
                lastSuccessfulSyncElapsedMillis: 1_000,
                selfStatus: caution,
                selfStatusAcknowledged: false,
                nowElapsedMillis: 31_000
            )),
            .pausedWithPendingStatus(
                cause: .relay,
                rideRecording: true,
                status: caution,
                isClearing: false
            )
        )
        XCTAssertEqual(
            GroupPresencePolicy.evaluate(input(
                lastSuccessfulSyncElapsedMillis: 1_000,
                selfStatus: caution,
                selfStatusAcknowledged: false,
                isClearingStatus: true,
                nowElapsedMillis: 31_000
            )),
            .pausedWithPendingStatus(
                cause: .relay,
                rideRecording: true,
                status: caution,
                isClearing: true
            )
        )
    }

    func testHealthyStatusUsesStatusAgeNotPositionAge() {
        let pill = GroupPresencePolicy.evaluate(input(
            selfStatus: caution,
            selfStatusAge: .minutes(12),
            selfStatusAcknowledged: true
        ))
        XCTAssertEqual(pill, .statusReminder(status: caution, age: .minutes(12)))
    }

    func testNotSharingCanStillReportAcknowledgedStatus() {
        let pill = GroupPresencePolicy.evaluate(input(
            isSharingPosition: false,
            selfStatus: alert,
            selfStatusAcknowledged: true
        ))
        XCTAssertEqual(
            pill,
            .notSharing(status: alert, statusAcknowledged: true, isClearing: false)
        )
    }

    func testNotSharingPreservesClearingDeliveryState() {
        let pill = GroupPresencePolicy.evaluate(input(
            isSharingPosition: false,
            selfStatus: caution,
            selfStatusAcknowledged: false,
            isClearingStatus: true
        ))
        XCTAssertEqual(
            pill,
            .notSharing(status: caution, statusAcknowledged: false, isClearing: true)
        )
    }

    func testThresholdBoundaryAndSuccessfulSyncAreTheOnlyPauseExit() {
        let below = GroupPresencePolicy.evaluate(input(
            lastSuccessfulSyncElapsedMillis: 1_000,
            lastFailureKind: .noInternet,
            nowElapsedMillis: 30_999
        ))
        XCTAssertEqual(below, .none)

        let atBoundary = GroupPresencePolicy.evaluate(input(
            lastSuccessfulSyncElapsedMillis: 1_000,
            lastFailureKind: .noInternet,
            nowElapsedMillis: 31_000
        ))
        XCTAssertNotEqual(atBoundary, .none)

        let afterSuccess = GroupPresencePolicy.evaluate(input(
            lastSuccessfulSyncElapsedMillis: 31_000,
            lastFailureKind: nil,
            nowElapsedMillis: 31_000
        ))
        XCTAssertEqual(afterSuccess, .none)
    }

    private func input(
        sessionActive: Bool = true,
        lastSuccessfulSyncElapsedMillis: Int64? = 10_000,
        lastOwnPositionAckElapsedMillis: Int64? = 9_000,
        lastFailureKind: GroupSyncFailureKind? = nil,
        isSharingPosition: Bool = true,
        isRideRecording: Bool = true,
        selfStatus: RiderStatus? = nil,
        selfStatusAge: StatusAge.Bucket = .unknown,
        selfStatusAcknowledged: Bool = false,
        isClearingStatus: Bool = false,
        syncIntervalSec: Int = 10,
        nowElapsedMillis: Int64 = 15_000
    ) -> GroupPresencePolicy.Input {
        .init(
            sessionActive: sessionActive,
            lastSuccessfulSyncElapsedMillis: lastSuccessfulSyncElapsedMillis,
            lastOwnPositionAckElapsedMillis: lastOwnPositionAckElapsedMillis,
            lastFailureKind: lastFailureKind,
            isSharingPosition: isSharingPosition,
            isRideRecording: isRideRecording,
            selfStatus: selfStatus,
            selfStatusAge: selfStatusAge,
            selfStatusAcknowledged: selfStatusAcknowledged,
            isClearingStatus: isClearingStatus,
            syncIntervalSec: syncIntervalSec,
            nowElapsedMillis: nowElapsedMillis
        )
    }
}
