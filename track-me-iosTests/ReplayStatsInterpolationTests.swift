import XCTest
@testable import track_me_ios

final class ReplayStatsInterpolationTests: XCTestCase {
    private func pointsWithStop() -> [GPSPoint] {
        [
            GPSPoint(latitude: 0, longitude: 0, altitude: 0, accuracy: 1, speed: 1, timestamp: Date(timeIntervalSince1970: 0)),
            GPSPoint(latitude: 0, longitude: 0.001, altitude: 0, accuracy: 1, speed: 1, timestamp: Date(timeIntervalSince1970: 1)),
            GPSPoint(latitude: 0, longitude: 0.001, altitude: 0, accuracy: 1, speed: 0, timestamp: Date(timeIntervalSince1970: 10)),
            GPSPoint(latitude: 0, longitude: 0.002, altitude: 0, accuracy: 1, speed: 1, timestamp: Date(timeIntervalSince1970: 11))
        ]
    }

    func testFinalProgressUsesAuthoritativeTotals() {
        let fallback = ReplayStats(distanceMeters: 2_000, durationMillis: 11_000, averageSpeedMetersPerSecond: 0)
        let result = ReplayStatsInterpolation.replayStatsAtProgress(points: pointsWithStop(), progress: 1, fallback: fallback)
        XCTAssertEqual(result.distanceMeters, fallback.distanceMeters, accuracy: 0.001)
        XCTAssertEqual(result.durationMillis, fallback.durationMillis)
    }

    func testInitialProgressIsNearZero() {
        let fallback = ReplayStats(distanceMeters: 2_000, durationMillis: 11_000, averageSpeedMetersPerSecond: 0)
        let result = ReplayStatsInterpolation.replayStatsAtProgress(points: pointsWithStop(), progress: 0, fallback: fallback)
        XCTAssertEqual(result.distanceMeters, 0, accuracy: 0.001)
        XCTAssertEqual(result.durationMillis, 0)
    }

    func testTimeFractionIncludesMidRouteStop() {
        let points = pointsWithStop()
        XCTAssertEqual(ReplayStatsInterpolation.routeTimeFraction(points: points, progress: 0.5), 0.5, accuracy: 0.01)
        XCTAssertEqual(ReplayStatsInterpolation.routeDistanceFraction(points: points, progress: 0.5), 0.5, accuracy: 0.02)
    }
}
