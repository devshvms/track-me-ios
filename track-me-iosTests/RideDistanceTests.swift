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

    func testDistanceSortsPointsByTimestampBeforeAccumulating() {
        let base = Date(timeIntervalSince1970: 0)
        let first = GPSPoint(latitude: 0, longitude: 0, altitude: 0, accuracy: 1, speed: 0, timestamp: base)
        let middle = GPSPoint(latitude: 0, longitude: 0.01, altitude: 0, accuracy: 1, speed: 0, timestamp: base.addingTimeInterval(1))
        let last = GPSPoint(latitude: 0, longitude: 0.02, altitude: 0, accuracy: 1, speed: 0, timestamp: base.addingTimeInterval(2))

        XCTAssertEqual(
            RideDistance.totalKm([last, first, middle]),
            RideDistance.totalKm([first, middle, last]),
            accuracy: 0.001
        )
    }

    func testAverageSpeedGuardsZeroAndNegativeDuration() {
        XCTAssertEqual(HistoryRideMetrics.averageSpeedKmh(distanceKm: 10, duration: 1_800), 20.0, accuracy: 0.001)
        XCTAssertEqual(HistoryRideMetrics.averageSpeedKmh(distanceKm: 10, duration: 0), 0)
        XCTAssertEqual(HistoryRideMetrics.averageSpeedKmh(distanceKm: 10, duration: -1), 0)
    }

    func testHistoryMetricDurationFormatting() {
        XCTAssertEqual(HistoryMetricFormat.duration(0), "00:00:00")
        XCTAssertEqual(HistoryMetricFormat.duration(3_661), "01:01:01")
        XCTAssertEqual(HistoryMetricFormat.duration(-1), "00:00:00")
    }

    func testHistoryMetricDistanceAndSpeedFormatting() {
        XCTAssertEqual(HistoryMetricFormat.km(12.34), "12.3 km")
        XCTAssertEqual(HistoryMetricFormat.kmh(16.25), "16.2 km/h")
    }
}
