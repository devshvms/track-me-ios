//
//  RideRecoveryLogicTests.swift
//
//  Pure-logic coverage for the ride-recovery slice (parity row 13): the shared
//  default-title generator and the recovery-summary toast selection. The
//  SwiftData sweep itself is exercised via the simulator manual tests in
//  prompt 02 §Verification (needs a ModelContainer).
//

import XCTest
@testable import track_me_ios

@MainActor
final class RideRecoveryLogicTests: XCTestCase {

    private func point(speed: Double) -> GPSPoint {
        GPSPoint(latitude: 0, longitude: 0, altitude: 0, accuracy: 5, speed: speed, timestamp: Date())
    }

    private func date(hour: Int) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 7; c.day = 19; c.hour = hour; c.minute = 0
        return Calendar.current.date(from: c)!
    }

    func testTitleDistinguishesBikeFromWalk() {
        // 5 m/s -> 18 km/h > 15 threshold -> Bike Ride
        XCTAssertEqual(RideTitleGenerator.make(startTime: date(hour: 8), points: [point(speed: 5)]),
                       "Morning Bike Ride")
        // 2 m/s -> 7.2 km/h -> Walk/Run
        XCTAssertEqual(RideTitleGenerator.make(startTime: date(hour: 8), points: [point(speed: 2)]),
                       "Morning Walk/Run")
    }

    func testTitleTimeOfDayBuckets() {
        XCTAssertTrue(RideTitleGenerator.make(startTime: date(hour: 6), points: []).hasPrefix("Morning"))
        XCTAssertTrue(RideTitleGenerator.make(startTime: date(hour: 14), points: []).hasPrefix("Afternoon"))
        XCTAssertTrue(RideTitleGenerator.make(startTime: date(hour: 18), points: []).hasPrefix("Evening"))
        XCTAssertTrue(RideTitleGenerator.make(startTime: date(hour: 23), points: []).hasPrefix("Night"))
        XCTAssertTrue(RideTitleGenerator.make(startTime: date(hour: 2), points: []).hasPrefix("Night"))
    }

    func testEmptyPointsDefaultsToWalkRun() {
        XCTAssertEqual(RideTitleGenerator.make(startTime: date(hour: 13), points: []), "Afternoon Walk/Run")
    }

    func testSelectedPersonaOverridesSpeedInference() {
        XCTAssertEqual(
            RideTitleGenerator.make(startTime: date(hour: 14), persona: .run, maxSpeedKmh: 32),
            "Afternoon Run"
        )
        XCTAssertEqual(
            RideTitleGenerator.make(startTime: date(hour: 18), persona: .bikeDrive, maxSpeedKmh: 4),
            "Evening Motorbike Ride"
        )
    }

    func testAutoPersonaStillUsesSpeedInference() {
        XCTAssertEqual(
            RideTitleGenerator.make(startTime: date(hour: 8), persona: .auto, maxSpeedKmh: 20),
            "Morning Bike Ride"
        )
    }

    func testGeneratedTitleDetectionPreservesCustomNames() {
        XCTAssertTrue(RideTitleGenerator.isGeneratedTitle("Night Bike Ride"))
        XCTAssertTrue(RideTitleGenerator.isGeneratedTitle("Morning BikeDrive"))
        XCTAssertFalse(RideTitleGenerator.isGeneratedTitle("Airport training run"))
    }

    func testRecoveryToastVariants() {
        XCTAssertNil(RideRecoveryManager.toastMessage(for: RecoverySummary(recoveredCount: 0, discardedCount: 0)))
        XCTAssertEqual(RideRecoveryManager.toastMessage(for: RecoverySummary(recoveredCount: 1, discardedCount: 0)),
                       "1 interrupted ride was recovered")
        XCTAssertEqual(RideRecoveryManager.toastMessage(for: RecoverySummary(recoveredCount: 3, discardedCount: 0)),
                       "3 interrupted rides were recovered")
        XCTAssertEqual(RideRecoveryManager.toastMessage(for: RecoverySummary(recoveredCount: 0, discardedCount: 1)),
                       "Removed 1 empty interrupted ride")
        XCTAssertEqual(RideRecoveryManager.toastMessage(for: RecoverySummary(recoveredCount: 2, discardedCount: 1)),
                       "Recovered 2 interrupted, removed 1 empty")
    }

    func testTrailingDwellCutoffTrimsLongStationaryTailAfterRealTrip() {
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        // Real ~500m movement (~0.0045 deg lat) followed by 15 min stationary indoor cluster
        let moving = [
            GPSPoint(latitude: 28.5000, longitude: 77.2000, altitude: 0, accuracy: 5, speed: 5.0, timestamp: base),
            GPSPoint(latitude: 28.5025, longitude: 77.2000, altitude: 0, accuracy: 5, speed: 6.0, timestamp: base.addingTimeInterval(60)),
            GPSPoint(latitude: 28.5045, longitude: 77.2000, altitude: 0, accuracy: 5, speed: 0.4, timestamp: base.addingTimeInterval(120)),
        ]
        let tail = [
            GPSPoint(latitude: 28.50455, longitude: 77.20005, altitude: 0, accuracy: 12, speed: 0.2, timestamp: base.addingTimeInterval(420)),
            GPSPoint(latitude: 28.50452, longitude: 77.20002, altitude: 0, accuracy: 15, speed: 0.0, timestamp: base.addingTimeInterval(120 + 15 * 60)),
        ]
        let cutoff = RideRecoveryManager.trailingDwellCutoff(for: moving + tail)
        XCTAssertEqual(cutoff?.keepEndIndexInclusive, 2)
        XCTAssertEqual(cutoff?.cutoffTimestamp, base.addingTimeInterval(120))
    }

    func testTrailingDwellCutoffPreservesShortOrBriefStationaryTails() {
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        // Less than 10 minutes stationary tail -> keep all
        let briefPoints = [
            GPSPoint(latitude: 28.5000, longitude: 77.2000, altitude: 0, accuracy: 5, speed: 5.0, timestamp: base),
            GPSPoint(latitude: 28.5045, longitude: 77.2000, altitude: 0, accuracy: 5, speed: 0.2, timestamp: base.addingTimeInterval(120)),
            GPSPoint(latitude: 28.50452, longitude: 77.20002, altitude: 0, accuracy: 10, speed: 0.0, timestamp: base.addingTimeInterval(120 + 9 * 60)),
        ]
        XCTAssertNil(RideRecoveryManager.trailingDwellCutoff(for: briefPoints))

        // Stationary whole trip (< 100m movement) -> preserve
        let indoorPoints = [
            GPSPoint(latitude: 28.5000, longitude: 77.2000, altitude: 0, accuracy: 10, speed: 0.2, timestamp: base),
            GPSPoint(latitude: 28.5001, longitude: 77.2000, altitude: 0, accuracy: 10, speed: 0.1, timestamp: base.addingTimeInterval(15 * 60)),
        ]
        XCTAssertNil(RideRecoveryManager.trailingDwellCutoff(for: indoorPoints))
    }

    func testCreditRecoveredRidesFoldsQualifyingTripsIdempotently() async {
        let suite = "RideRecoveryCreditTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = RideStatsStore(defaults: defaults)
        let firstId = UUID()
        let junkId = UUID()
        let summary = RecoverySummary(
            recoveredCount: 2,
            discardedCount: 0,
            recovered: [
                RecoveredRide(
                    rideId: junkId,
                    endTime: Date(timeIntervalSince1970: 1_780_000_000),
                    distanceMeters: 4,
                    activeDurationMillis: 20_000,
                    qualifiesForStats: false
                ),
                RecoveredRide(
                    rideId: firstId,
                    endTime: Date(timeIntervalSince1970: 1_780_001_000),
                    distanceMeters: 2_500,
                    activeDurationMillis: 450_000,
                    qualifiesForStats: true
                ),
            ]
        )

        await RideRecoveryManager.creditRecoveredRides(summary: summary, statsStore: store, onNewCredit: false)
        var stats = await store.current()
        XCTAssertEqual(stats.totalRides, 1)
        XCTAssertEqual(stats.totalDistanceMeters, 2_500, accuracy: 0.01)

        // Idempotent replay does not double-count
        await RideRecoveryManager.creditRecoveredRides(summary: summary, statsStore: store, onNewCredit: false)
        stats = await store.current()
        XCTAssertEqual(stats.totalRides, 1)
    }
}
