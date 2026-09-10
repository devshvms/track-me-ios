import XCTest
@testable import track_me_ios

final class TrackingV2SessionTests: XCTestCase {
    private func sample(_ seconds: Int64, _ metres: Double) -> TrackingV2Sample {
        TrackingV2Sample(latitude: 0, longitude: metres / 111_195,
            horizontalAccuracyMeters: 5, elapsedRealtimeMillis: seconds * 1_000,
            gpsSpeedMetersPerSecond: 4, gpsSpeedAccuracyMetersPerSecond: 0.5,
            motionEnergyMetersPerSecondSquared: 1, motionSampleAgeMillis: 0,
            cumulativeStepCount: nil, stepAgeMillis: nil, stepCadenceHz: nil,
            persona: .cycling, powerMode: .normal)
    }
    func testRestoreKeepsCheckpointAndDoesNotBridgeDowntime() {
        let session = TrackingV2Session()
        session.reset(persona: .cycling, distance: 500, duration: 100_000, peak: 8)
        session.add(sample(100, 10_000))
        XCTAssertEqual(session.distanceMeters, 500, accuracy: 0.001)
        XCTAssertEqual(session.movingDurationMillis, 100_000)
        XCTAssertEqual(session.maxSpeedMps, 8)
    }
    func testPauseDoesNotChargeTravelAndResetClearsRide() {
        let session = TrackingV2Session()
        session.reset(persona: .cycling)
        for i in 0...12 { session.add(sample(Int64(i * 2), Double(i * 8))) }
        let distance = session.distanceMeters
        let duration = session.movingDurationMillis
        session.pause()
        session.add(sample(30, 500))
        session.resume()
        session.add(sample(32, 1_000))
        XCTAssertEqual(session.distanceMeters, distance, accuracy: 0.001)
        XCTAssertEqual(session.movingDurationMillis, duration)
        session.reset(persona: .cycling)
        XCTAssertEqual(session.distanceMeters, 0)
        XCTAssertEqual(session.movingDurationMillis, 0)
    }
}
