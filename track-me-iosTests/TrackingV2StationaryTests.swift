import XCTest
@testable import track_me_ios

/// Synthetic metres around (0,0), matching Android's stationary regression scenarios.
final class TrackingV2StationaryTests: XCTestCase {
    private func fix(_ seconds: Int64, east: Double = 0, north: Double = 0,
                     speed: Float? = 0, speedAccuracy: Float? = 0.4, accuracy: Float = 6,
                     energy: Float? = 0.14, motionAge: Int64? = 0, steps: Int64? = nil,
                     stepAge: Int64? = nil, persona: RidePersona = .walk,
                     power: TrackingV2PowerMode = .normal) -> TrackingV2Sample {
        TrackingV2Sample(latitude: north / 111_195, longitude: east / 111_195,
            horizontalAccuracyMeters: accuracy, elapsedRealtimeMillis: seconds * 1_000,
            gpsSpeedMetersPerSecond: speed, gpsSpeedAccuracyMetersPerSecond: speedAccuracy,
            motionEnergyMetersPerSecondSquared: energy, motionSampleAgeMillis: motionAge,
            cumulativeStepCount: steps, stepAgeMillis: stepAge,
            stepCadenceHz: stepAge == 0 ? 1 : nil, persona: persona, powerMode: power)
    }

    func testTwoHourCorrelatedOptimisticGPSCloudCannotResumeConfirmedStop() {
        for power in [TrackingV2PowerMode.normal, .batterySaver] {
            let session = TrackingV2Session()
            session.reset(persona: .walk)
            for i in 0...360 {
                session.add(fix(Int64(i * 2), east: Double(i * 2), speed: 1,
                    energy: 0.3, steps: Int64(i * 2), stepAge: 0, power: power))
            }
            for i in 1...30 { session.add(fix(Int64(720 + i * 2), east: 720, steps: 720, power: power)) }
            let distance = session.distanceMeters
            let duration = session.movingDurationMillis
            let route = session.snapshot.routeSegments
            for i in 1...3_600 {
                let angle = Double(i) * 2 * Double.pi / 90
                session.add(fix(Int64(780 + i * 2), east: 720 + 9 * sin(angle),
                    north: 9 * (1 - cos(angle)), speed: 0.8, speedAccuracy: 0.1, accuracy: 4,
                    energy: i % 7 == 0 ? 0.3 : 0.04, motionAge: i % 20 < 10 ? 9_000 : 0,
                    steps: 720, power: power))
            }
            XCTAssertEqual(session.movingDurationMillis, duration, power.rawValue)
            XCTAssertEqual(session.distanceMeters, distance)
            XCTAssertEqual(session.snapshot.routeSegments, route)
            XCTAssertEqual(session.snapshot.stationaryEntryCount, 1)
            XCTAssertTrue(session.isAutoPaused)
        }
    }

    func testStationaryGPSSpeedWithoutDepartureNeverResumes() {
        let session = TrackingV2Session()
        session.reset(persona: .walk)
        for i in 0...30 { session.add(fix(Int64(i * 2))) }
        for i in 1...300 { session.add(fix(Int64(60 + i * 2), speed: 2, speedAccuracy: 0.1)) }
        XCTAssertEqual(session.movingDurationMillis, 0)
        XCTAssertEqual(session.distanceMeters, 0)
        XCTAssertTrue(session.isAutoPaused)
    }

    func testGPSDepartureNeverRecountsTimeCreditedWithDebugAutoPauseOff() {
        let session = TrackingV2Session()
        session.reset(persona: .walk)
        for i in 0...30 { session.add(fix(Int64(i * 2))) }
        for i in 1...30 {
            session.add(fix(Int64(60 + i * 2), east: Double(i) * 1.2, speed: 0.6,
                speedAccuracy: 0.1), autoPauseEnabled: i > 15)
        }
        XCTAssertEqual(session.movingDurationMillis, 60_000)
        XCTAssertTrue((30...39).contains(session.distanceMeters))
    }

    func testHeldPhonePausesOnceThroughTenMinutesOfUrbanDrift() {
        for power in [TrackingV2PowerMode.normal, .batterySaver] {
            let session = TrackingV2Session()
            session.reset(persona: .walk)
            for i in 0...300 {
                let state = session.add(fix(Int64(i * 2), east: Double(i % 7 - 3) * 3,
                    north: Double(i % 5 - 2) * 2, speed: i % 11 == 0 ? 1.2 : 0.35,
                    speedAccuracy: i % 11 == 0 ? 0.2 : 0.8, accuracy: 60,
                    energy: i % 4 == 0 ? 0.28 : 0.14, steps: 100, power: power))
                if i >= 12 {
                    XCTAssertEqual(state.movementState, .stationary, "\(power) at \(i)")
                    XCTAssertEqual(state.currentSpeedMetersPerSecond, 0)
                    XCTAssertEqual(session.movingDurationMillis, 0)
                    XCTAssertTrue(session.isAutoPaused)
                    XCTAssertLessThanOrEqual(state.distanceMeters, 10)
                    XCTAssertLessThanOrEqual(state.routeSegments.flatMap { $0 }.count, 1)
                }
            }
            XCTAssertEqual(session.snapshot.stationaryEntryCount, 1)
        }
    }

    func testPhoneMotionAndRawDriftAloneNeverProveTravel() {
        let estimator = TrackingV2Estimator()
        estimator.reset(persona: .walk)
        for i in 0...90 {
            let state = estimator.add(fix(Int64(i * 2), east: Double(i % 7 - 3) * 4,
                speed: nil, accuracy: 65, energy: 0.3))
            XCTAssertNotEqual(state.movementState, .moving)
            XCTAssertEqual(state.distanceMeters, 0)
            XCTAssertTrue(state.routeSegments.isEmpty)
            XCTAssertEqual(state.currentSpeedMetersPerSecond, 0)
        }
    }

    func testUncertainGPSWithAbsentOrStaleMotionDoesNotClaimStationary() {
        for age in [nil, Int64(9_000)] {
            let session = TrackingV2Session()
            session.reset(persona: .walk)
            for i in 0...90 {
                session.add(fix(Int64(i * 2), east: Double(i % 3), speed: nil, accuracy: 60,
                    energy: age == nil ? nil : 0.02, motionAge: age))
            }
            XCTAssertNotEqual(session.snapshot.movementState, .stationary)
            XCTAssertEqual(session.movingDurationMillis, 0)
            XCTAssertEqual(session.distanceMeters, 0)
        }
    }

    func testSlowStepsResumePromptlyWithoutChargingSeatedInterval() {
        let session = TrackingV2Session()
        session.reset(persona: .walk)
        for i in 0...90 { session.add(fix(Int64(i * 2), steps: 100)) }
        XCTAssertEqual(session.snapshot.movementState, .stationary)
        let stoppedDuration = session.movingDurationMillis
        for i in 1...15 {
            let previousDistance = session.distanceMeters
            let state = session.add(fix(Int64(180 + i * 2), east: Double(i) * 0.72, speed: 0.18,
                energy: 0.24, steps: Int64(100 + i), stepAge: 0))
            XCTAssertEqual(state.movementState, .moving)
            XCTAssertFalse(session.isAutoPaused)
            XCTAssertGreaterThanOrEqual(session.distanceMeters + 0.001, previousDistance)
        }
        XCTAssertEqual(session.movingDurationMillis - stoppedDuration, 30_000)
        XCTAssertTrue((8...13).contains(session.distanceMeters))
        XCTAssertEqual(session.snapshot.stationaryEntryCount, 1)
    }

    func testGPSOnlySlowWalkingAndLowAccelerationVehiclesResume() {
        for persona in [RidePersona.walk, .run, .cycling, .bikeDrive] {
            let session = TrackingV2Session()
            session.reset(persona: persona)
            for i in 0...30 { session.add(fix(Int64(i * 2), energy: 0.02, persona: persona)) }
            let speed: Float = persona == .walk ? 0.6 : 3
            for i in 1...30 {
                session.add(fix(Int64(60 + i * 2), east: Double(i * 2) * Double(speed),
                    speed: speed, speedAccuracy: 0.1, energy: 0.03, persona: persona))
            }
            XCTAssertEqual(session.snapshot.movementState, .moving)
            XCTAssertTrue((50 * Double(speed)...65 * Double(speed)).contains(session.distanceMeters))
            XCTAssertTrue((50_000...60_000).contains(session.movingDurationMillis))
        }
    }

    func testStationarySpeedAndRouteFreezeAfterMovement() {
        let session = TrackingV2Session()
        session.reset(persona: .walk)
        for i in 0...15 {
            session.add(fix(Int64(i * 2), east: Double(i * 2), speed: 1, energy: 0.3,
                steps: Int64(i * 2), stepAge: 0))
        }
        for i in 1...30 {
            session.add(fix(Int64(30 + i * 2), east: 30 + Double(i % 3 - 1), speed: 0.3,
                speedAccuracy: 0.8, accuracy: 40, steps: 30))
        }
        let paused = session.snapshot
        let duration = session.movingDurationMillis
        for i in 1...90 {
            session.add(fix(Int64(90 + i * 2), east: 30 + Double(i % 5 - 2), speed: 0.3,
                speedAccuracy: 0.8, accuracy: 40, energy: i % 4 == 0 ? 0.25 : 0.14, steps: 30))
        }
        XCTAssertEqual(session.snapshot.movementState, .stationary)
        XCTAssertEqual(session.distanceMeters, paused.distanceMeters)
        XCTAssertEqual(session.movingDurationMillis, duration)
        XCTAssertEqual(session.snapshot.routeSegments, paused.routeSegments)
        XCTAssertEqual(session.snapshot.currentSpeedMetersPerSecond, 0)
    }

    func testOneDisplacedFixIsNotCoherentTravelOrResume() {
        let session = TrackingV2Session()
        session.reset(persona: .walk)
        for i in 0...90 { session.add(fix(Int64(i * 2), speed: nil, accuracy: 20)) }
        for i in 1...10 {
            let state = session.add(fix(Int64(180 + i * 2), east: 40, speed: nil, accuracy: 20, energy: 0.3))
            XCTAssertEqual(state.movementState, .stationary)
            XCTAssertEqual(state.distanceMeters, 0)
            XCTAssertEqual(session.movingDurationMillis, 0)
        }
    }

    func testAmbiguousDurationWaitsForConfirmationAndDoesNotBecomeSpeedSpike() {
        let session = TrackingV2Session()
        session.reset(persona: .walk)
        session.add(fix(0, speed: nil, steps: 0))
        session.add(fix(2, east: 0.72, speed: nil, steps: 0))
        session.add(fix(4, east: 1.44, speed: nil, steps: 0))
        XCTAssertEqual(session.movingDurationMillis, 0)
        session.add(fix(6, east: 2.16, speed: nil, steps: 3, stepAge: 0))
        XCTAssertEqual(session.movingDurationMillis, 6_000)
        let cycling = TrackingV2Session()
        cycling.reset(persona: .cycling)
        for i in 0...30 {
            cycling.add(fix(Int64(i * 2), east: Double(i * 8), speed: 4, energy: 0.02, persona: .cycling))
        }
        XCTAssertEqual(cycling.maxSpeedMps, 4, accuracy: 0.05)
    }

    func testDebugAutoPauseOffCountsObservedTimeButNotDriftOrManualPause() {
        let session = TrackingV2Session()
        session.reset(persona: .walk)
        for i in 0...15 { session.add(fix(Int64(i * 2)), autoPauseEnabled: false) }
        XCTAssertEqual(session.movingDurationMillis, 30_000)
        XCTAssertEqual(session.snapshot.movementState, .stationary)
        XCTAssertFalse(session.isAutoPaused)
        XCTAssertEqual(session.distanceMeters, 0)
        XCTAssertTrue(session.snapshot.routeSegments.isEmpty)
        session.pause()
        session.add(fix(32, east: 100), autoPauseEnabled: false)
        session.resume()
        session.add(fix(34, east: 150), autoPauseEnabled: false)
        XCTAssertEqual(session.movingDurationMillis, 30_000)
        XCTAssertEqual(session.distanceMeters, 0)
        for i in 1...15 { session.add(fix(Int64(34 + i * 2), east: 150)) }
        XCTAssertEqual(session.movingDurationMillis, 30_000)
        XCTAssertTrue(session.isAutoPaused)
    }

    func testGPSOutageClearsPendingTimeAndDoesNotBridgeVehicleDistance() {
        let session = TrackingV2Session()
        session.reset(persona: .cycling)
        session.add(fix(0, persona: .cycling))
        session.add(fix(2, persona: .cycling))
        session.add(fix(60, east: 100, persona: .cycling))
        XCTAssertEqual(session.snapshot.movementState, .gpsDegraded)
        XCTAssertEqual(session.movingDurationMillis, 0)
        XCTAssertEqual(session.distanceMeters, 0)
        XCTAssertFalse(session.isAutoPaused)
    }
}
