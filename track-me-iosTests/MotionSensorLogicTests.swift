import XCTest
@testable import track_me_ios

@MainActor
final class MotionSensorLogicTests: XCTestCase {

    func testShouldTreatDeviceAsStationary() {
        // Sensor unavailable -> false
        XCTAssertFalse(MotionSensorManager.shouldTreatDeviceAsStationary(sensorAvailable: false, sampleReceived: true, motionEnergy: 0.10))

        // No sample received -> false
        XCTAssertFalse(MotionSensorManager.shouldTreatDeviceAsStationary(sensorAvailable: true, sampleReceived: false, motionEnergy: 0.10))

        // Energy < threshold -> true
        XCTAssertTrue(MotionSensorManager.shouldTreatDeviceAsStationary(sensorAvailable: true, sampleReceived: true, motionEnergy: 0.10))

        // Energy >= threshold -> false (boundary check, < not <=)
        XCTAssertFalse(MotionSensorManager.shouldTreatDeviceAsStationary(sensorAvailable: true, sampleReceived: true, motionEnergy: 0.18))
        XCTAssertFalse(MotionSensorManager.shouldTreatDeviceAsStationary(sensorAvailable: true, sampleReceived: true, motionEnergy: 0.50))
    }

    func testDistanceShouldAccumulate() {
        // Normal accumulation
        XCTAssertTrue(MotionSensorManager.distanceShouldAccumulate(state: .tracking, isPaused: false, dist: 1.5, effectiveSpeed: 0.31))

        // Paused -> false
        XCTAssertFalse(MotionSensorManager.distanceShouldAccumulate(state: .tracking, isPaused: true, dist: 1.5, effectiveSpeed: 0.31))

        // Distance too small -> false
        XCTAssertFalse(MotionSensorManager.distanceShouldAccumulate(state: .tracking, isPaused: false, dist: 1.49, effectiveSpeed: 0.31))
        XCTAssertTrue(MotionSensorManager.distanceShouldAccumulate(state: .tracking, isPaused: false, dist: 1.5, effectiveSpeed: 0.31))

        // Speed too slow -> false
        XCTAssertFalse(MotionSensorManager.distanceShouldAccumulate(state: .tracking, isPaused: false, dist: 1.5, effectiveSpeed: 0.30))
        XCTAssertTrue(MotionSensorManager.distanceShouldAccumulate(state: .tracking, isPaused: false, dist: 1.5, effectiveSpeed: 0.31))

        // Not tracking -> false
        XCTAssertFalse(MotionSensorManager.distanceShouldAccumulate(state: .paused, isPaused: false, dist: 1.5, effectiveSpeed: 0.31))
    }

    func testUnitConversionEdgeCase() {
        // 0.01 G -> ~0.0981 m/s^2 (< 0.18) -> stationary
        let g1 = 0.01
        let ms1 = MotionSensorManager.convertGToMS2(g: g1)
        XCTAssertTrue(MotionSensorManager.shouldTreatDeviceAsStationary(sensorAvailable: true, sampleReceived: true, motionEnergy: ms1))

        // 0.05 G -> ~0.4905 m/s^2 (>= 0.18) -> moving
        let g2 = 0.05
        let ms2 = MotionSensorManager.convertGToMS2(g: g2)
        XCTAssertFalse(MotionSensorManager.shouldTreatDeviceAsStationary(sensorAvailable: true, sampleReceived: true, motionEnergy: ms2))
    }
}
