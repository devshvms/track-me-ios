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

    func testReconstructedAggregateExcludesPausedSegmentsAndLongTimeGaps() {
        let base = Date(timeIntervalSince1970: 1_000)
        let points = [
            GPSPoint(latitude: 0, longitude: 0, altitude: 0, accuracy: 1, speed: 2, timestamp: base),
            GPSPoint(latitude: 0, longitude: 0.001, altitude: 0, accuracy: 1, speed: 3, timestamp: base.addingTimeInterval(10)),
            GPSPoint(latitude: 0, longitude: 0.002, altitude: 0, accuracy: 1, speed: 0, timestamp: base.addingTimeInterval(20), isPaused: true),
            GPSPoint(latitude: 0, longitude: 0.003, altitude: 0, accuracy: 1, speed: 4, timestamp: base.addingTimeInterval(30)),
            GPSPoint(latitude: 0, longitude: 0.004, altitude: 0, accuracy: 1, speed: 5, timestamp: base.addingTimeInterval(100))
        ]

        let aggregate = RideMetrics.reconstructed(from: points)

        XCTAssertEqual(aggregate.distanceMeters, 222.4, accuracy: 1)
        XCTAssertEqual(aggregate.movingDurationMillis, 10_000)
        XCTAssertEqual(aggregate.maxSpeedMps, 5)
        XCTAssertEqual(aggregate.avgSpeedMps, aggregate.distanceMeters / 10, accuracy: 0.001)
        XCTAssertEqual(aggregate.pointCount, 5)
    }

    func testLiveAggregateUsesFilteredDistanceAndMovingDuration() {
        let aggregate = RideAggregateSnapshot.live(
            distanceMeters: 1_500,
            movingDurationMillis: 300_000,
            maxSpeedMps: 12,
            pointCount: 42
        )

        XCTAssertEqual(aggregate.distanceMeters, 1_500)
        XCTAssertEqual(aggregate.movingDurationMillis, 300_000)
        XCTAssertEqual(aggregate.avgSpeedMps, 5)
        XCTAssertEqual(aggregate.maxSpeedMps, 12)
        XCTAssertEqual(aggregate.pointCount, 42)
    }

    func testRidePresentationPrefersPersistedAggregate() {
        let ride = Ride(startTime: Date(timeIntervalSince1970: 0))
        ride.points = [
            GPSPoint(latitude: 0, longitude: 0, altitude: 0, accuracy: 1, speed: 0, timestamp: .now),
            GPSPoint(latitude: 0, longitude: 1, altitude: 0, accuracy: 1, speed: 0, timestamp: .now)
        ]
        ride.applyAggregate(RideAggregateSnapshot.live(
            distanceMeters: 2_000,
            movingDurationMillis: 400_000,
            maxSpeedMps: 8,
            pointCount: 20
        ))

        let metrics = HistoryRideMetrics(ride: ride)
        XCTAssertEqual(metrics.distanceKm, 2)
        XCTAssertEqual(metrics.duration, 400)
        XCTAssertEqual(metrics.avgSpeedKmh, 18)
    }

    func testHistoryMetricsKeepAverageSpeedConsistentWithPauseExcludedDuration() {
        let ride = Ride(startTime: Date(timeIntervalSince1970: 0))
        let activeDurationMillis: Int64 = 300_000
        let distanceMeters = 5_000.0
        ride.applyAggregate(RideAggregateSnapshot.live(
            distanceMeters: distanceMeters,
            movingDurationMillis: TimeInterval(activeDurationMillis),
            maxSpeedMps: 8,
            pointCount: 42
        ))

        let metrics = HistoryRideMetrics(ride: ride)

        XCTAssertEqual(metrics.duration, 300, accuracy: 0.001)
        XCTAssertEqual(metrics.avgSpeedKmh, 60, accuracy: 0.001)
        XCTAssertEqual(
            metrics.avgSpeedKmh,
            metrics.distanceKm / (metrics.duration / 3_600),
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
