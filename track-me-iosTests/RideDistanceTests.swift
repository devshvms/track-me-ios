import XCTest
@testable import track_me_ios

final class RideDistanceTests: XCTestCase {
    func testDistanceUsesGreatCircleMeters() {
        let points = [
            GPSPoint(latitude: 0, longitude: 0, altitude: 0, accuracy: 1, speed: 0, timestamp: .now),
            GPSPoint(latitude: 0, longitude: 0.01, altitude: 0, accuracy: 1, speed: 0, timestamp: .now)
        ]
        XCTAssertEqual(RideDistance.kilometers(points), 1.112, accuracy: 0.01)
    }

    func testSinglePointDistanceIsZeroForRecoveredRide() {
        let point = GPSPoint(latitude: 10, longitude: 10, altitude: 0, accuracy: 1, speed: 0, timestamp: .now)
        XCTAssertEqual(RideDistance.meters([point]), 0)
    }
}
