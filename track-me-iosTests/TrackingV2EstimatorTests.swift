import Foundation
import XCTest
@testable import track_me_ios

final class TrackingV2EstimatorTests: XCTestCase {
    func testManualPauseIgnoresFixesAndStepsUntilIdempotentResume() {
        let estimator = TrackingV2Estimator()
        estimator.reset(persona: .walk)
        estimator.add(sample(east: 0, elapsed: 0, persona: .walk, steps: 0))
        estimator.add(sample(east: 7.2, elapsed: 10_000, persona: .walk, steps: 10, stepAge: 0))
        let beforePause = estimator.snapshot().distanceMeters

        estimator.pause()
        estimator.pause()
        estimator.add(sample(
            east: 100,
            elapsed: 20_000,
            persona: .walk,
            accuracy: 40,
            steps: 30,
            stepAge: 0,
            powerMode: .batterySaver
        ))
        estimator.add(sample(east: 200, elapsed: 30_000, persona: .walk, steps: 50, stepAge: 0))
        XCTAssertEqual(estimator.snapshot().distanceMeters, beforePause, accuracy: 0.001)
        estimator.resume()
        estimator.resume()
        estimator.add(sample(east: 500, elapsed: 40_000, persona: .walk, steps: 50))
        estimator.add(sample(east: 507.2, elapsed: 50_000, persona: .walk, steps: 60, stepAge: 0))

        let result = estimator.finish()
        XCTAssertEqual(result.manualPauseCount, 1)
        XCTAssertEqual(result.ignoredManualPauseSampleCount, 2)
        XCTAssertEqual(result.degradedSampleCount, 0)
        XCTAssertEqual(result.powerRestrictedSampleCount, 0)
        XCTAssertEqual(result.poorAccuracySampleCount, 0)
        XCTAssertFalse(result.manualPauseActive)
        XCTAssertEqual(result.sampleCount, 4)
        XCTAssertLessThan(result.distanceMeters, beforePause + 10)
        XCTAssertEqual(result.rawRouteSegments.count, 2)
    }

    func testPauseBeforeFirstFixAndStopWhilePausedRemainEmpty() {
        let estimator = TrackingV2Estimator()
        estimator.reset(persona: .run)
        estimator.pause()
        estimator.add(sample(east: 80, elapsed: 10_000, persona: .run, steps: 40, stepAge: 0))

        let result = estimator.finish()
        XCTAssertEqual(result.distanceMeters, 0)
        XCTAssertEqual(result.sampleCount, 0)
        XCTAssertEqual(result.ignoredManualPauseSampleCount, 1)
        XCTAssertTrue(result.manualPauseActive)
        XCTAssertTrue(result.routeSegments.isEmpty)
    }

    func testPedestrianStepsBridgeUnobservedGapWithoutGeometryChord() {
        let estimator = TrackingV2Estimator()
        estimator.reset(persona: .walk)
        estimator.add(sample(east: 0, elapsed: 0, persona: .walk, steps: 0))
        estimator.add(sample(east: 100, elapsed: 20_000, persona: .walk, steps: 20, stepAge: 0))
        for index in 1...4 {
            estimator.add(sample(
                east: 100 + Double(index) * 2,
                elapsed: 20_000 + Int64(index) * 2_000,
                persona: .walk,
                steps: 20 + Int64(index),
                stepAge: 0
            ))
        }

        let result = estimator.finish()
        XCTAssertEqual(result.unobservedGapCount, 1)
        XCTAssertEqual(result.estimatedGapStepCount, 20)
        XCTAssertEqual(result.estimatedGapDistanceMeters, 14.4, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(result.distanceMeters, 14.4)
    }

    func testGapWithoutEligibleStepsNeverFabricatesDistance() {
        for persona in [RidePersona.walk, .cycling, .carDrive] {
            let estimator = TrackingV2Estimator()
            estimator.reset(persona: persona)
            estimator.add(sample(east: 0, elapsed: 0, persona: persona))
            estimator.add(sample(east: 500, elapsed: 20_000, persona: persona))
            let result = estimator.finish()
            XCTAssertEqual(result.distanceMeters, 0, persona.rawValue)
            XCTAssertEqual(result.estimatedGapStepCount, 0, persona.rawValue)
        }
    }

    func testStationaryAlternatingDriftIsNotMovement() {
        let estimator = TrackingV2Estimator()
        estimator.reset(persona: .carDrive)
        for index in 0..<30 {
            let east = switch index % 3 {
            case 1: 10.0
            case 2: -10.0
            default: 0.0
            }
            estimator.add(sample(
                east: east,
                elapsed: Int64(index) * 2_000,
                persona: .carDrive,
                accuracy: 8,
                motionEnergy: 0.02
            ))
        }

        let result = estimator.finish()
        XCTAssertEqual(result.movementState, .stationary)
        XCTAssertEqual(result.distanceMeters, 0, accuracy: 0.01)
        XCTAssertLessThanOrEqual(result.routeSegments.flatMap { $0 }.count, 1)
    }

    func testMissingSpeedStillAdmitsCoherentVehicleMovement() {
        let estimator = TrackingV2Estimator()
        estimator.reset(persona: .carDrive)
        for index in 0...10 {
            estimator.add(sample(
                east: Double(index) * 10,
                elapsed: Int64(index) * 2_000,
                persona: .carDrive,
                accuracy: 5,
                motionEnergy: 0.03
            ))
        }

        let result = estimator.finish()
        XCTAssertEqual(result.movementState, .moving)
        XCTAssertTrue((95...103).contains(result.distanceMeters), "distance=\(result.distanceMeters)")
        XCTAssertEqual(result.missingSpeedCount, result.sampleCount)
    }

    func testBatterySaverPedestriansRetainCoherentCoordinateAndStepEvidence() {
        for persona in [RidePersona.walk, .run] {
            let estimator = TrackingV2Estimator()
            estimator.reset(persona: persona)
            for index in 0...10 {
                estimator.add(sample(
                    east: Double(index) * 10,
                    elapsed: Int64(index) * 10_000,
                    persona: persona,
                    accuracy: 18,
                    gpsSpeed: 1,
                    motionEnergy: 0.25,
                    steps: Int64(index) * 10,
                    stepAge: 0,
                    cadence: 1,
                    powerMode: .batterySaver
                ))
            }

            let result = estimator.finish()
            XCTAssertEqual(result.movementState, .moving, persona.rawValue)
            XCTAssertTrue((90...110).contains(result.distanceMeters),
                          "\(persona.rawValue) distance=\(result.distanceMeters)")
            XCTAssertEqual(result.powerRestrictedSampleCount, result.sampleCount, persona.rawValue)
            XCTAssertEqual(result.poorAccuracySampleCount, 0, persona.rawValue)
            XCTAssertEqual(result.unobservedGapCount, 0, persona.rawValue)
            XCTAssertEqual(result.detectedStepCount, 100, persona.rawValue)
        }
    }

    func testDegradedRandomJumpsDoNotBecomeDistance() {
        let estimator = TrackingV2Estimator()
        estimator.reset(persona: .bikeDrive)
        let randomCloud = [0.0, 40.0, -40.0, 30.0, -30.0, 45.0, -35.0]
        for (index, east) in randomCloud.enumerated() {
            estimator.add(sample(
                east: east,
                elapsed: Int64(index) * 10_000,
                persona: .bikeDrive,
                accuracy: 35,
                motionEnergy: 0.3,
                powerMode: .batterySaver
            ))
        }

        let result = estimator.finish()
        XCTAssertEqual(result.distanceMeters, 0, accuracy: 0.01)
        XCTAssertLessThanOrEqual(result.routeSegments.flatMap { $0 }.count, 1)
    }

    func testIsolatedJumpDoesNotPoisonCoordinateRecovery() {
        let estimator = TrackingV2Estimator()
        estimator.reset(persona: .cycling)
        let coordinates = [0.0, 10, 20, 30, 500] + stride(from: 40, through: 200, by: 10).map(Double.init)
        for (index, east) in coordinates.enumerated() {
            estimator.add(sample(east: east, elapsed: Int64(index) * 2_000,
                                 persona: .cycling, accuracy: 5, gpsSpeed: 4, motionEnergy: 0.3))
        }
        let result = estimator.finish()
        XCTAssertGreaterThanOrEqual(result.rejectedOutlierCount, 1)
        XCTAssertTrue((195...205).contains(result.distanceMeters), "distance=\(result.distanceMeters)")
        XCTAssertEqual(result.movementState, .moving)
        XCTAssertLessThan(TrackingV2Estimator.haversineMeters(result.routeSegments.last!.last!,
                                                            point(east: 200, north: 0)), 2)
    }

    func testExplicitPersonaRemainsLockedAndVehicleDistanceNeverUsesSteps() {
        let estimator = TrackingV2Estimator()
        estimator.reset(persona: .cycling)
        for index in 0..<8 {
            estimator.add(sample(
                east: Double(index) * 10,
                elapsed: Int64(index) * 2_000,
                persona: .walk,
                gpsSpeed: 5,
                motionEnergy: 0.3,
                steps: Int64(index) * 8,
                stepAge: 0
            ))
        }
        let result = estimator.finish()
        XCTAssertEqual(result.personaMismatchCount, 8)
        XCTAssertEqual(result.distanceMeters, result.coordinateDistanceMeters, accuracy: 0.001)
        XCTAssertGreaterThan(result.rawStepDistanceMeters, 0)
    }

    func testAutoPauseIsStableAndResumeKeepsOneSolidRoute() {
        let estimator = TrackingV2Estimator()
        estimator.reset(persona: .cycling)
        for index in 0...5 { estimator.add(movingCyclingSample(Double(index) * 10, Int64(index) * 2_000)) }
        let beforeStop = estimator.snapshot().distanceMeters
        for index in 1...8 {
            estimator.add(sample(
                east: 50 + (index.isMultiple(of: 2) ? 2 : -2),
                elapsed: 10_000 + Int64(index) * 2_000,
                persona: .cycling,
                gpsSpeed: 0,
                motionEnergy: 0.02
            ))
        }
        let afterStop = estimator.snapshot().distanceMeters
        for index in 1...5 {
            estimator.add(movingCyclingSample(50 + Double(index) * 10, 26_000 + Int64(index) * 2_000))
        }

        let result = estimator.finish()
        XCTAssertEqual(result.stationaryEntryCount, 1)
        XCTAssertLessThanOrEqual(result.movingEntryCount, 2)
        XCTAssertLessThanOrEqual(afterStop - beforeStop, 10)
        XCTAssertEqual(result.routeSegments.count, 1)
        XCTAssertEqual(result.movementState, .moving)
    }

    func testSlowRunWarmupStaysMovingAndCadenceBurstIsDiscarded() {
        let estimator = TrackingV2Estimator()
        estimator.reset(persona: .run)
        var steps: Int64 = 0
        for index in 0..<12 {
            if index > 0 { steps += index == 6 ? 100 : 2 }
            estimator.add(sample(
                east: Double(index) * 2,
                elapsed: Int64(index) * 2_000,
                persona: .run,
                gpsSpeed: index < 3 ? 0.4 : 1,
                motionEnergy: 0.22,
                steps: steps,
                stepAge: 0,
                cadence: index < 3 ? 1 : 2
            ))
        }
        let result = estimator.finish()
        XCTAssertEqual(result.movementState, .moving)
        XCTAssertGreaterThan(result.discardedImplausibleStepCount, 0)
        XCTAssertGreaterThan(result.distanceMeters, 0)
        XCTAssertEqual(Float(result.rawStepDistanceMeters) / Float(result.detectedStepCount), 1.05, accuracy: 0.01)
    }

    func testFinishCleansRouteWithoutChangingStatsOrEndpoints() {
        let estimator = TrackingV2Estimator()
        estimator.reset(persona: .cycling)
        for index in 0..<30 {
            estimator.add(sample(
                east: Double(index) * 4,
                north: index.isMultiple(of: 2) ? 2 : -2,
                elapsed: Int64(index) * 2_000,
                persona: .cycling,
                accuracy: 16,
                gpsSpeed: 2,
                motionEnergy: 0.25
            ))
        }
        let live = estimator.snapshot()
        let result = estimator.finish()
        XCTAssertEqual(result.distanceMeters, live.distanceMeters)
        XCTAssertGreaterThanOrEqual(result.rawRouteSegments.flatMap { $0 }.count,
                                    result.routeSegments.flatMap { $0 }.count)
        XCTAssertEqual(result.rawRouteSegments.first?.first, result.routeSegments.first?.first)
        XCTAssertEqual(result.rawRouteSegments.last?.last, result.routeSegments.last?.last)
    }

    func testCurvedRouteIsNotSimplifiedIntoItsEndpointChord() {
        let estimator = TrackingV2Estimator()
        estimator.reset(persona: .cycling)
        for index in 0...9 {
            let angle = (-90.0 + Double(index) * 10.0) * .pi / 180
            estimator.add(sample(
                east: 50 * cos(angle),
                north: 50 + 50 * sin(angle),
                elapsed: Int64(index) * 2_000,
                persona: .cycling,
                accuracy: 4,
                gpsSpeed: 4,
                motionEnergy: 0.25
            ))
        }

        let route = estimator.finish().routeSegments.flatMap { $0 }
        let middleOfCurve = point(east: 35.36, north: 14.64)
        XCTAssertGreaterThan(route.count, 2)
        XCTAssertLessThan(route.map { TrackingV2Estimator.haversineMeters($0, middleOfCurve) }.min() ?? .infinity, 9)
    }

    func testUTurnRetainsReversalInsteadOfBecomingOneChord() {
        let estimator = TrackingV2Estimator()
        estimator.reset(persona: .cycling)
        var uTurn = stride(from: 0, through: 50, by: 10).map { (Double($0), 0.0) }
        uTurn.append((55, 5))
        uTurn.append((50, 10))
        uTurn.append(contentsOf: stride(from: 40, through: 0, by: -10).map { (Double($0), 15.0) })

        for (index, coordinate) in uTurn.enumerated() {
            estimator.add(sample(
                east: coordinate.0,
                north: coordinate.1,
                elapsed: Int64(index) * 2_000,
                persona: .cycling,
                accuracy: 4,
                gpsSpeed: 4,
                motionEnergy: 0.3
            ))
        }

        let route = estimator.finish().routeSegments.flatMap { $0 }
        XCTAssertTrue(route.contains { TrackingV2Estimator.haversineMeters($0, point(east: 55, north: 5)) < 9 })
        XCTAssertLessThan(TrackingV2Estimator.haversineMeters(route.last!, point(east: 0, north: 15)), 2)
    }

    func testResetClearsProcessLocalEvidenceBeforeNextRide() {
        let estimator = TrackingV2Estimator()
        estimator.reset(persona: .cycling)
        for index in 0..<8 {
            estimator.add(movingCyclingSample(Double(index) * 10, Int64(index) * 2_000))
        }
        estimator.pause()
        XCTAssertGreaterThan(estimator.snapshot().distanceMeters, 0)

        estimator.reset(persona: .run)
        let reset = estimator.finish()
        XCTAssertEqual(reset.distanceMeters, 0)
        XCTAssertEqual(reset.sampleCount, 0)
        XCTAssertEqual(reset.manualPauseCount, 0)
        XCTAssertFalse(reset.manualPauseActive)
        XCTAssertTrue(reset.routeSegments.isEmpty)
        XCTAssertEqual(reset.strideLengthMeters, 1.05)
    }
}

private extension TrackingV2EstimatorTests {
    func movingCyclingSample(_ east: Double, _ elapsed: Int64) -> TrackingV2Sample {
        sample(east: east, elapsed: elapsed, persona: .cycling, gpsSpeed: 5, motionEnergy: 0.3)
    }

    func sample(
        east: Double,
        north: Double = 0,
        elapsed: Int64,
        persona: RidePersona,
        accuracy: Float = 6,
        gpsSpeed: Float? = nil,
        motionEnergy: Float? = 0.02,
        steps: Int64? = nil,
        stepAge: Int64? = nil,
        cadence: Float? = nil,
        powerMode: TrackingV2PowerMode = .normal
    ) -> TrackingV2Sample {
        let point = point(east: east, north: north)
        return TrackingV2Sample(
            latitude: point.latitude,
            longitude: point.longitude,
            horizontalAccuracyMeters: accuracy,
            elapsedRealtimeMillis: elapsed,
            gpsSpeedMetersPerSecond: gpsSpeed,
            gpsSpeedAccuracyMetersPerSecond: gpsSpeed == nil ? nil : 0.4,
            motionEnergyMetersPerSecondSquared: motionEnergy,
            motionSampleAgeMillis: motionEnergy == nil ? nil : 0,
            cumulativeStepCount: steps,
            stepAgeMillis: stepAge,
            stepCadenceHz: cadence,
            persona: persona,
            powerMode: powerMode
        )
    }

    func point(east: Double, north: Double) -> TrackingV2Point {
        TrackingV2Point(
            latitude: north / Self.metresPerDegree,
            longitude: east / Self.metresPerDegree
        )
    }

    static let metresPerDegree = 111_320.0
}
