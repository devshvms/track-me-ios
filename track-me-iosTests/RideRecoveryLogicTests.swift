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
}
