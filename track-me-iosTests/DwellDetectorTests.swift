import XCTest
import CoreLocation
@testable import track_me_ios

final class DwellDetectorTests: XCTestCase {

    func testFeatureDisabledReturnsActiveTrackingAlways() {
        let detector = DwellDetector(isAutoTripChainingEnabled: false)
        let coord = CLLocationCoordinate2D(latitude: 12.9716, longitude: 77.5946)
        let res = detector.evaluate(coordinate: coord, speedKmh: 0.0, now: Date())
        XCTAssertEqual(res.state, DwellState.activeTracking)
        XCTAssertFalse(res.shouldAutoEndRide)
        XCTAssertFalse(res.shouldAutoStartNextRide)
    }

    func testNormalRidingStaysActive() {
        let detector = DwellDetector(isAutoTripChainingEnabled: true)
        let coord = CLLocationCoordinate2D(latitude: 12.9716, longitude: 77.5946)
        let res = detector.evaluate(coordinate: coord, speedKmh: 24.5, now: Date())
        XCTAssertEqual(res.state, DwellState.activeTracking)
        XCTAssertFalse(res.shouldAutoEndRide)
    }

    func testTrafficLightStopUnder45sResetsOnResumption() {
        let detector = DwellDetector(isAutoTripChainingEnabled: true, stationaryConfirmationDuration: 45.0)
        let coord = CLLocationCoordinate2D(latitude: 12.9716, longitude: 77.5946)
        let t0 = Date(timeIntervalSince1970: 10_000)

        // Stop starts
        var res = detector.evaluate(coordinate: coord, speedKmh: 0.5, now: t0)
        XCTAssertEqual(res.state, DwellState.activeTracking)

        // 30 seconds later
        res = detector.evaluate(coordinate: coord, speedKmh: 0.2, now: t0.addingTimeInterval(30))
        XCTAssertEqual(res.state, DwellState.activeTracking)

        // Resumes at 18 km/h at 40s (< 45s)
        let coordMoved = CLLocationCoordinate2D(latitude: 12.9720, longitude: 77.5946)
        res = detector.evaluate(coordinate: coordMoved, speedKmh: 18.0, now: t0.addingTimeInterval(40))
        XCTAssertEqual(res.state, DwellState.activeTracking)
    }

    func testDwellingAnchorDroppedAfter45sAndIndoorPacingRemainsInDwell() {
        let detector = DwellDetector(
            isAutoTripChainingEnabled: true,
            autoEndDwellMinutes: 10,
            dwellAnchorRadiusMeters: 75.0,
            stationaryConfirmationDuration: 45.0
        )

        let anchorCoord = CLLocationCoordinate2D(latitude: 12.9716, longitude: 77.5946)
        let t0 = Date(timeIntervalSince1970: 100_000)

        // Stop starts
        _ = detector.evaluate(coordinate: anchorCoord, speedKmh: 0.0, now: t0)

        // 45 seconds later, anchor confirmed
        let res45 = detector.evaluate(coordinate: anchorCoord, speedKmh: 0.5, now: t0.addingTimeInterval(45))
        XCTAssertEqual(res45.state, DwellState.dwelling)
        XCTAssertEqual(res45.dwellAnchorCoordinate?.latitude ?? 0, anchorCoord.latitude, accuracy: 0.0001)

        // Walking inside apartment ~22m away with indoor GPS drift speeds (1.8 km/h)
        let indoorCoord = CLLocationCoordinate2D(latitude: anchorCoord.latitude + 0.0002, longitude: anchorCoord.longitude)
        let resIndoor = detector.evaluate(coordinate: indoorCoord, speedKmh: 1.8, now: t0.addingTimeInterval(180))
        XCTAssertEqual(resIndoor.state, DwellState.dwelling)
        XCTAssertTrue((15.0...30.0).contains(resIndoor.distanceFromAnchorMeters))
        XCTAssertFalse(resIndoor.shouldAutoEndRide)

        // 10 minutes reached (t0 + 600s)
        let resEnd = detector.evaluate(coordinate: indoorCoord, speedKmh: 0.0, now: t0.addingTimeInterval(600))
        XCTAssertEqual(resEnd.state, DwellState.tripAutoEnded)
        XCTAssertTrue(resEnd.shouldAutoEndRide)
        XCTAssertEqual(resEnd.autoEndTimestamp, t0)
        XCTAssertTrue(resEnd.shouldPruneTrailingPoints)
    }

    func testBreakoutFromDwellBeforeTimeoutAbortsAutoEnd() {
        let detector = DwellDetector(
            isAutoTripChainingEnabled: true,
            autoEndDwellMinutes: 10,
            dwellAnchorRadiusMeters: 75.0,
            stationaryConfirmationDuration: 45.0
        )

        let anchorCoord = CLLocationCoordinate2D(latitude: 12.9716, longitude: 77.5946)
        let t0 = Date(timeIntervalSince1970: 100_000)

        _ = detector.evaluate(coordinate: anchorCoord, speedKmh: 0.0, now: t0)
        _ = detector.evaluate(coordinate: anchorCoord, speedKmh: 0.0, now: t0.addingTimeInterval(45))
        XCTAssertEqual(detector.state, DwellState.dwelling)

        // User gets back on bike 3 minutes in and rides away (166m away at 18 km/h)
        let awayCoord = CLLocationCoordinate2D(latitude: anchorCoord.latitude + 0.0015, longitude: anchorCoord.longitude)
        let resAway = detector.evaluate(coordinate: awayCoord, speedKmh: 18.0, now: t0.addingTimeInterval(180))
        XCTAssertEqual(resAway.state, DwellState.activeTracking)
        XCTAssertFalse(resAway.shouldAutoEndRide)
    }

    func testStandbyModeAutoStartsWhenMovingAwayWithSustainedSpeed() {
        let detector = DwellDetector(
            isAutoTripChainingEnabled: true,
            breakoutRadiusMeters: 150.0,
            breakoutSpeedThresholdKmh: 8.0,
            breakoutConfirmationDuration: 20.0
        )

        let homeCoord = CLLocationCoordinate2D(latitude: 12.9716, longitude: 77.5946)
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        detector.transitionToStandby(lastAnchorCoordinate: homeCoord, now: t0)
        XCTAssertEqual(detector.state, DwellState.standbyWaitingForNextTrip)

        // Still near home (30m away)
        let nearCoord = CLLocationCoordinate2D(latitude: homeCoord.latitude + 0.0002, longitude: homeCoord.longitude)
        var res = detector.evaluate(coordinate: nearCoord, speedKmh: 0.0, now: t0.addingTimeInterval(3600)) // 1h later
        XCTAssertEqual(res.state, DwellState.standbyWaitingForNextTrip)
        XCTAssertFalse(res.shouldAutoStartNextRide)

        // Breaks out > 150m at transit speed (277m away at 20 km/h) within the 2h standby window
        let outCoord = CLLocationCoordinate2D(latitude: homeCoord.latitude + 0.0025, longitude: homeCoord.longitude)
        let tBreak = t0.addingTimeInterval(5400)
        res = detector.evaluate(coordinate: outCoord, speedKmh: 20.0, now: tBreak)
        XCTAssertEqual(res.state, DwellState.standbyWaitingForNextTrip)
        XCTAssertFalse(res.shouldAutoStartNextRide)

        // Sustained for 20 seconds
        let outCoord2 = CLLocationCoordinate2D(latitude: homeCoord.latitude + 0.0035, longitude: homeCoord.longitude)
        let resConfirmed = detector.evaluate(coordinate: outCoord2, speedKmh: 22.0, now: tBreak.addingTimeInterval(20))
        XCTAssertEqual(resConfirmed.state, DwellState.activeTracking)
        XCTAssertTrue(resConfirmed.shouldAutoStartNextRide)
        XCTAssertEqual(resConfirmed.autoStartTimestamp, tBreak)
    }

    func testPoorHorizontalAccuracyDoesNotDropAnchorOrTriggerBreakout() {
        let detector = DwellDetector(
            isAutoTripChainingEnabled: true,
            breakoutRadiusMeters: 150.0,
            breakoutSpeedThresholdKmh: 8.0,
            stationaryConfirmationDuration: 45.0,
            breakoutConfirmationDuration: 20.0
        )

        let coord = CLLocationCoordinate2D(latitude: 12.9716, longitude: 77.5946)
        let t0 = Date(timeIntervalSince1970: 2_000_000)

        // Poor accuracy (> 60m) and invalid (< 0) fixes must not confirm dwell anchor
        _ = detector.evaluate(coordinate: coord, speedKmh: 0.2, now: t0, horizontalAccuracy: 120.0)
        let resCoarse = detector.evaluate(coordinate: coord, speedKmh: 0.2, now: t0.addingTimeInterval(60), horizontalAccuracy: 120.0)
        XCTAssertEqual(resCoarse.state, DwellState.activeTracking)
        let resInvalid = detector.evaluate(coordinate: coord, speedKmh: 0.2, now: t0.addingTimeInterval(120), horizontalAccuracy: -1.0)
        XCTAssertEqual(resInvalid.state, DwellState.activeTracking)

        // Clean GPS fix (15m) establishes anchor after 45s
        let tClean = t0.addingTimeInterval(200)
        _ = detector.evaluate(coordinate: coord, speedKmh: 0.2, now: tClean, horizontalAccuracy: 15.0)
        let resDwelling = detector.evaluate(coordinate: coord, speedKmh: 0.2, now: tClean.addingTimeInterval(45), horizontalAccuracy: 15.0)
        XCTAssertEqual(resDwelling.state, DwellState.dwelling)

        // In standby, coarse fixes must not cause false trip breakout
        detector.transitionToStandby(lastAnchorCoordinate: coord, now: t0)
        let farCoord = CLLocationCoordinate2D(latitude: coord.latitude + 0.003, longitude: coord.longitude)
        _ = detector.evaluate(coordinate: farCoord, speedKmh: 22.0, now: t0.addingTimeInterval(100), horizontalAccuracy: 120.0)
        let resStandbyCoarse = detector.evaluate(coordinate: farCoord, speedKmh: 22.0, now: t0.addingTimeInterval(130), horizontalAccuracy: 120.0)
        XCTAssertEqual(resStandbyCoarse.state, DwellState.standbyWaitingForNextTrip)
        XCTAssertFalse(resStandbyCoarse.shouldAutoStartNextRide)
    }

    func testStandbyModeStopsAutomaticallyAfterTwoHours() {
        let detector = DwellDetector(isAutoTripChainingEnabled: true)
        let homeCoord = CLLocationCoordinate2D(latitude: 12.9716, longitude: 77.5946)
        let t0 = Date(timeIntervalSince1970: 3_000_000)

        detector.transitionToStandby(lastAnchorCoordinate: homeCoord, now: t0)
        let nearRes = detector.evaluate(coordinate: homeCoord, speedKmh: 0.0, now: t0.addingTimeInterval(7199), horizontalAccuracy: 10.0)
        XCTAssertEqual(nearRes.state, DwellState.standbyWaitingForNextTrip)
        XCTAssertFalse(nearRes.shouldStopStandby)

        let farCoord = CLLocationCoordinate2D(latitude: homeCoord.latitude + 0.003, longitude: homeCoord.longitude)
        let expiredRes = detector.evaluate(coordinate: farCoord, speedKmh: 25.0, now: t0.addingTimeInterval(7200), horizontalAccuracy: 10.0)
        XCTAssertEqual(expiredRes.state, DwellState.activeTracking)
        XCTAssertTrue(expiredRes.shouldStopStandby)
        XCTAssertFalse(expiredRes.shouldAutoStartNextRide)
    }

    func testDisablingAutoChainingDuringStandbyStopsStandby() {
        let detector = DwellDetector(isAutoTripChainingEnabled: true)
        let homeCoord = CLLocationCoordinate2D(latitude: 12.9716, longitude: 77.5946)
        let t0 = Date(timeIntervalSince1970: 4_000_000)

        detector.transitionToStandby(lastAnchorCoordinate: homeCoord, now: t0)
        detector.isAutoTripChainingEnabled = false
        let res = detector.evaluate(coordinate: homeCoord, speedKmh: 0.0, now: t0.addingTimeInterval(30))
        XCTAssertEqual(res.state, DwellState.activeTracking)
        XCTAssertTrue(res.shouldStopStandby)
        XCTAssertEqual(detector.state, DwellState.activeTracking)
    }
}
