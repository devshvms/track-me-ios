import XCTest
import CoreLocation
@testable import track_me_ios

final class HandsFreeReliabilityPolicyTests: XCTestCase {

    // MARK: - Invariant 1: Wall-clock elapsed time for undo & short indoor tests

    func testInvariant1_StationaryIndoorRideOver90sWallClockIsNotShortIndoorTest() {
        // Stationary indoor test sitting open for 2m (120s elapsed, 0s moving, 0m distance):
        // passing wall-clock elapsed time prevents false classification as a short <90s test.
        XCTAssertFalse(
            RideStartAbortPolicy.isShortIndoorTest(
                durationInMillis: 120_000,
                distanceMeters: 0.0
            )
        )
        XCTAssertFalse(
            RideStartAbortPolicy.canOfferPostCommitUndo(
                durationInMillis: 12_000,
                distanceMeters: 0.0
            )
        )
        XCTAssertTrue(
            RideStartAbortPolicy.isShortIndoorTest(
                durationInMillis: 45_000,
                distanceMeters: 0.0
            )
        )
    }

    // MARK: - Invariant 2: 1Hz timer-driven DwellDetector under 3-minute GPS throttling

    func testInvariant2_TimerDrivenDwellFiresAutoEndAcrossAllDwellWindowsWithZeroGpsCallbacksAfter180s() {
        let anchor = CLLocationCoordinate2D(latitude: 12.9716, longitude: 77.5946)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        for dwellMinutes in [5, 10, 15, 30] {
            let detector = DwellDetector(
                isAutoTripChainingEnabled: true,
                autoEndDwellMinutes: dwellMinutes,
                isAutoEndCropDwellEnabled: true
            )

            // Phase 1: GPS delivers stationary fixes from t=0s to t=180s (3 minutes)
            var lastResult = DwellEvaluationResult(state: .activeTracking)
            for second in 0...180 {
                let now = t0.addingTimeInterval(TimeInterval(second))
                lastResult = detector.evaluate(
                    coordinate: anchor,
                    speedKmh: 0.0,
                    now: now,
                    horizontalAccuracy: 10.0
                )
            }
            XCTAssertEqual(
                lastResult.state,
                .dwelling,
                "Expected dwelling by t=180s for \(dwellMinutes)m window"
            )
            XCTAssertFalse(lastResult.shouldAutoEndRide)

            // Phase 2: At t=180s GPS throttles to 15m filter -> ZERO further OS GPS callbacks.
            // 1Hz timer ticks evaluate DwellDetector using cached anchor + wall clock.
            let targetSeconds = dwellMinutes * 60
            var autoEndedAtSecond: Int?
            var autoEndResult: DwellEvaluationResult?

            for second in 181...(targetSeconds + 5) {
                let shouldEval = HandsFreeReliabilityPolicy.shouldEvaluateDwellOnTimerTick(
                    isAutoTripChainingEnabled: true,
                    isLiveShareBlockingDwell: false,
                    isAutoPaused: true,
                    isMotionStationary: true,
                    isGpsThrottled: true,
                    dwellState: detector.state
                )
                XCTAssertTrue(shouldEval, "Timer must evaluate DwellDetector while throttled")

                let now = t0.addingTimeInterval(TimeInterval(second))
                let tickResult = detector.evaluate(
                    coordinate: anchor,
                    speedKmh: 0.0,
                    now: now,
                    horizontalAccuracy: 10.0
                )
                if tickResult.shouldAutoEndRide {
                    autoEndedAtSecond = second
                    autoEndResult = tickResult
                    break
                }
            }

            XCTAssertEqual(
                autoEndedAtSecond,
                targetSeconds,
                "Expected Auto-End at exact \(targetSeconds)s for \(dwellMinutes)m dwell window"
            )
            XCTAssertEqual(autoEndResult?.autoEndTimestamp, t0)
            XCTAssertEqual(autoEndResult?.shouldPruneTrailingPoints, true)
        }
    }

    // MARK: - Invariants 3 & 4: Stationary throttled .gpsLost suppression & motion wake

    func testInvariants3And4_SuppressesGpsLostWhenThrottledStationaryAndUnthrottlesOnMotionWake() {
        XCTAssertTrue(
            HandsFreeReliabilityPolicy.shouldSuppressGpsLost(
                isGpsThrottled: true,
                isStationary: true
            )
        )
        XCTAssertFalse(
            HandsFreeReliabilityPolicy.shouldSuppressGpsLost(
                isGpsThrottled: false,
                isStationary: true
            )
        )
        XCTAssertFalse(
            HandsFreeReliabilityPolicy.shouldSuppressGpsLost(
                isGpsThrottled: true,
                isStationary: false
            )
        )

        XCTAssertTrue(
            HandsFreeReliabilityPolicy.shouldUnthrottleOnMotionWake(
                isGpsThrottled: true,
                isMotionStationary: false,
                hasMotionSample: true
            )
        )
        XCTAssertFalse(
            HandsFreeReliabilityPolicy.shouldUnthrottleOnMotionWake(
                isGpsThrottled: true,
                isMotionStationary: true,
                hasMotionSample: true
            )
        )
        XCTAssertFalse(
            HandsFreeReliabilityPolicy.shouldUnthrottleOnMotionWake(
                isGpsThrottled: false,
                isMotionStationary: false,
                hasMotionSample: true
            )
        )
        XCTAssertFalse(
            HandsFreeReliabilityPolicy.shouldUnthrottleOnMotionWake(
                isGpsThrottled: true,
                isMotionStationary: false,
                hasMotionSample: false
            ),
            "Sensorless devices without a hardware sample must not thrash GPS throttling"
        )
    }

    // MARK: - Invariant 5: Active Live Share suppresses dwell auto-end

    func testInvariant5_ActiveLiveShareSuppressesTimerDrivenDwellEvaluation() {
        XCTAssertFalse(
            HandsFreeReliabilityPolicy.shouldEvaluateDwellOnTimerTick(
                isAutoTripChainingEnabled: true,
                isLiveShareBlockingDwell: true,
                isAutoPaused: true,
                isMotionStationary: true,
                isGpsThrottled: true,
                dwellState: .dwelling
            )
        )
    }

    // MARK: - Invariant 6: Strict 2-hour standby cap

    func testInvariant6_StandbyExpiresStrictlyAtTwoHoursWithoutMovement() {
        let detector = DwellDetector(isAutoTripChainingEnabled: true)
        let anchor = CLLocationCoordinate2D(latitude: 12.9716, longitude: 77.5946)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        detector.transitionToStandby(lastAnchorCoordinate: anchor, now: t0)

        let beforeCap = detector.evaluate(
            coordinate: anchor,
            speedKmh: 0.0,
            now: t0.addingTimeInterval(7_199),
            horizontalAccuracy: 10.0
        )
        XCTAssertEqual(beforeCap.state, .standbyWaitingForNextTrip)
        XCTAssertFalse(beforeCap.shouldStopStandby)

        let atCap = detector.evaluate(
            coordinate: anchor,
            speedKmh: 0.0,
            now: t0.addingTimeInterval(7_200),
            horizontalAccuracy: 10.0
        )
        XCTAssertEqual(atCap.state, .activeTracking)
        XCTAssertTrue(atCap.shouldStopStandby)
        XCTAssertFalse(atCap.shouldAutoStartNextRide)
    }

    // MARK: - ForgottenRideNotice coordination & Home anti-duplication

    func testForgottenRideNoticeSuppressedWhenAutoTripChainingEnabled() {
        XCTAssertFalse(
            ForgottenRideNotice.shouldAsk(
                stillnessSeconds: ForgottenRideNotice.stillnessBeforeNoticeSeconds,
                alreadyAsked: false,
                isTracking: true,
                autoTripChainingEnabled: true
            )
        )
        XCTAssertTrue(
            ForgottenRideNotice.shouldAsk(
                stillnessSeconds: ForgottenRideNotice.stillnessBeforeNoticeSeconds,
                alreadyAsked: false,
                isTracking: true,
                autoTripChainingEnabled: false
            )
        )
    }

    func testHomeTopSlotDiscoveryCardNeverStacksWithStandbyOrBroadcast() {
        XCTAssertTrue(
            HandsFreeReliabilityPolicy.shouldShowHomeHandsFreeTip(
                isStandbyActive: false,
                autoTripChainingEnabled: false,
                tipDismissed: false,
                hasUnreadBroadcast: false
            )
        )
        XCTAssertFalse(
            HandsFreeReliabilityPolicy.shouldShowHomeHandsFreeTip(
                isStandbyActive: true,
                autoTripChainingEnabled: false,
                tipDismissed: false,
                hasUnreadBroadcast: false
            )
        )
        XCTAssertFalse(
            HandsFreeReliabilityPolicy.shouldShowHomeHandsFreeTip(
                isStandbyActive: false,
                autoTripChainingEnabled: true,
                tipDismissed: false,
                hasUnreadBroadcast: false
            )
        )
        XCTAssertFalse(
            HandsFreeReliabilityPolicy.shouldShowHomeHandsFreeTip(
                isStandbyActive: false,
                autoTripChainingEnabled: false,
                tipDismissed: true,
                hasUnreadBroadcast: false
            )
        )
        XCTAssertFalse(
            HandsFreeReliabilityPolicy.shouldShowHomeHandsFreeTip(
                isStandbyActive: false,
                autoTripChainingEnabled: false,
                tipDismissed: false,
                hasUnreadBroadcast: true
            )
        )
    }

    // MARK: - §3.2 Cross-Platform Privacy-Safe Telemetry Contract

    func testHandsFreeTelemetryContractCoversAll7EventsWithZeroPII() {
        let samples = HandsFreeTelemetryContract.privacySamples
        let expectedNames: Set<String> = [
            "hands_free_offer_shown",
            "hands_free_enabled",
            "hands_free_disabled",
            "hands_free_standby_armed",
            "hands_free_ride_auto_started",
            "hands_free_ride_auto_ended",
            "hands_free_false_start_aborted"
        ]
        XCTAssertEqual(Set(samples.map(\.name)), expectedNames)

        let forbiddenFragments = ["lat", "lng", "lon", "coord", "email", "uid", "user_id", "ride_id", "title"]
        for event in samples {
            for key in event.properties.keys {
                let lower = key.lowercased()
                for forbidden in forbiddenFragments {
                    XCTAssertFalse(
                        lower.contains(forbidden),
                        "Forbidden PII/coordinate key '\(key)' in event '\(event.name)'"
                    )
                }
            }
        }
    }
}
