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
        XCTAssertTrue(distanceShouldAccumulate(state: .tracking, isPaused: false, dist: 1.5, effectiveSpeed: 0.31))
        
        // Paused -> false
        XCTAssertFalse(distanceShouldAccumulate(state: .tracking, isPaused: true, dist: 1.5, effectiveSpeed: 0.31))
        
        // Distance too small -> false
        XCTAssertFalse(distanceShouldAccumulate(state: .tracking, isPaused: false, dist: 1.49, effectiveSpeed: 0.31))
        XCTAssertTrue(distanceShouldAccumulate(state: .tracking, isPaused: false, dist: 1.5, effectiveSpeed: 0.31))
        
        // Speed too slow -> false
        XCTAssertFalse(distanceShouldAccumulate(state: .tracking, isPaused: false, dist: 1.5, effectiveSpeed: 0.30))
        XCTAssertTrue(distanceShouldAccumulate(state: .tracking, isPaused: false, dist: 1.5, effectiveSpeed: 0.31))
        
        // Not tracking -> false
        XCTAssertFalse(distanceShouldAccumulate(state: .paused, isPaused: false, dist: 1.5, effectiveSpeed: 0.31))
    }
    
    func testUnitConversionEdgeCase() {
        // 0.01 G -> ~0.0981 m/s^2 (< 0.18) -> stationary
        let g1 = 0.01
        let ms1 = g1 * 9.81
        XCTAssertTrue(MotionSensorManager.shouldTreatDeviceAsStationary(sensorAvailable: true, sampleReceived: true, motionEnergy: ms1))
        
        // 0.05 G -> ~0.4905 m/s^2 (>= 0.18) -> moving
        let g2 = 0.05
        let ms2 = g2 * 9.81
        XCTAssertFalse(MotionSensorManager.shouldTreatDeviceAsStationary(sensorAvailable: true, sampleReceived: true, motionEnergy: ms2))
    }
    
    // Pure helper matching the gate in TrackingManager
    private func distanceShouldAccumulate(state: TrackingState, isPaused: Bool, dist: Double, effectiveSpeed: Double) -> Bool {
        return state == .tracking && !isPaused && dist >= MotionSensorManager.minDistanceToAccumulate && effectiveSpeed > MotionSensorManager.minSpeedToAccumulate
    }
}
