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

    /// TASK-286. This vector used to assert the defect: 222.4 m against 10 s of moving time, an
    /// average of 22.24 m/s beside a stored maximum of 5. The name always said the long gap was
    /// excluded; the distance assertion did the opposite, because eligibility was applied to
    /// duration only. A GPS-gap chord must now contribute NEITHER distance NOR time.
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

        // Only the first interval is eligible: the middle two touch a paused point and the last is
        // a 70 s gap against a 25 s threshold.
        XCTAssertEqual(aggregate.distanceMeters, 111.2, accuracy: 1)
        XCTAssertEqual(aggregate.movingDurationMillis, 10_000)
        XCTAssertEqual(aggregate.avgSpeedMps, aggregate.distanceMeters / 10, accuracy: 0.001)
        XCTAssertEqual(aggregate.pointCount, 5)
        // The invariant the whole task exists for.
        XCTAssertGreaterThanOrEqual(aggregate.maxSpeedMps, aggregate.avgSpeedMps)
    }

    // MARK: - TASK-286 boundaries

    private func point(_ lonThousandths: Double, _ afterSeconds: TimeInterval, speed: Double, paused: Bool = false, base: Date = Date(timeIntervalSince1970: 1_000)) -> GPSPoint {
        GPSPoint(latitude: 0, longitude: lonThousandths / 1_000, altitude: 0, accuracy: 1, speed: speed, timestamp: base.addingTimeInterval(afterSeconds), isPaused: paused)
    }

    func testIntervalExactlyAtTheGapThresholdIsEligible() {
        let a = RideMetrics.reconstructed(from: [point(0, 0, speed: 1), point(1, 25, speed: 1)])
        XCTAssertEqual(a.distanceMeters, 111.2, accuracy: 1)
        XCTAssertEqual(a.movingDurationMillis, 25_000)
    }

    func testFirstIntervalAboveTheThresholdContributesNeither() {
        let a = RideMetrics.reconstructed(from: [point(0, 0, speed: 1), point(1, 25.001, speed: 1)])
        XCTAssertEqual(a.distanceMeters, 0, accuracy: 0.001)
        XCTAssertEqual(a.movingDurationMillis, 0)
        XCTAssertEqual(a.avgSpeedMps, 0)
    }

    func testNonMonotonicAndZeroLengthIntervalsContributeNothing() {
        // Sorting makes a duplicate timestamp a zero-length interval; it must not add geometry.
        let base = Date(timeIntervalSince1970: 1_000)
        let a = RideMetrics.reconstructed(from: [
            point(0, 0, speed: 1, base: base),
            point(1, 0, speed: 9, base: base)
        ])
        XCTAssertEqual(a.distanceMeters, 0, accuracy: 0.001)
        XCTAssertEqual(a.movingDurationMillis, 0)
        XCTAssertEqual(a.avgSpeedMps, 0)
    }

    func testPauseImmediatelyBeforeAndAfterAGapContributesNothing() {
        let a = RideMetrics.reconstructed(from: [
            point(0, 0, speed: 3, paused: true),
            point(1, 60, speed: 3),
            point(2, 120, speed: 3, paused: true)
        ])
        XCTAssertEqual(a.distanceMeters, 0, accuracy: 0.001)
        XCTAssertEqual(a.movingDurationMillis, 0)
    }

    func testNaNInfinityAndNegativeSpeedCannotCorruptTheAggregate() {
        let a = RideMetrics.reconstructed(from: [
            point(0, 0, speed: .nan),
            point(1, 10, speed: .infinity),
            point(2, 20, speed: -7)
        ])
        XCTAssertTrue(a.distanceMeters.isFinite)
        XCTAssertTrue(a.maxSpeedMps.isFinite)
        XCTAssertTrue(a.avgSpeedMps.isFinite)
        XCTAssertGreaterThanOrEqual(a.maxSpeedMps, 0)
        XCTAssertGreaterThanOrEqual(a.avgSpeedMps, 0)
        XCTAssertGreaterThanOrEqual(a.maxSpeedMps, a.avgSpeedMps)
    }

    func testConstantMovementYieldsCoherentAverageAndPeak() {
        let points = (0...5).map { point(Double($0), Double($0) * 10, speed: 11.12) }
        let a = RideMetrics.reconstructed(from: points)
        XCTAssertEqual(a.movingDurationMillis, 50_000)
        XCTAssertEqual(a.avgSpeedMps, 11.12, accuracy: 0.05)
        XCTAssertGreaterThanOrEqual(a.maxSpeedMps, a.avgSpeedMps)
    }

    func testVariableRouteKeepsPeakAtOrAboveAverage() {
        // Geometry says the rider sped up; the stored speeds deliberately under-read, which is the
        // case that produced an average faster than the peak before this task.
        let a = RideMetrics.reconstructed(from: [
            point(0, 0, speed: 0.1),
            point(1, 20, speed: 0.1),   // ~5.6 m/s chord
            point(3, 30, speed: 0.1),   // ~22.2 m/s chord
            point(4, 40, speed: 0.1)    // ~11.1 m/s chord
        ])
        XCTAssertGreaterThan(a.distanceMeters, 0)
        XCTAssertGreaterThanOrEqual(a.maxSpeedMps, a.avgSpeedMps)
    }

    func testNoEligibleEvidenceYieldsExplicitZeroRatherThanAPace() {
        let a = RideMetrics.reconstructed(from: [point(0, 0, speed: 4, paused: true)])
        XCTAssertEqual(a.distanceMeters, 0)
        XCTAssertEqual(a.movingDurationMillis, 0)
        XCTAssertEqual(a.avgSpeedMps, 0)
        XCTAssertEqual(a.maxSpeedMps, 0)
        XCTAssertEqual(a.pointCount, 1)
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

    func testElevationGainNeedsTenValidAltitudePoints() {
        XCTAssertNil(RideMetrics.elevationGainMeters(from: elevationPoints([0, 100, 0, 100, 0, 100, 0, 100, 0])))
    }

    func testElevationGainSuppressesNoisyFlatRoute() {
        let noisyFlat = [100.0, 100.8, 99.7, 100.6, 99.9, 100.5, 99.6, 100.7, 99.8, 100.4]

        XCTAssertEqual(RideMetrics.elevationGainMeters(from: elevationPoints(noisyFlat)) ?? -1, 0, accuracy: 0.001)
    }

    func testElevationGainUsesSmoothedAscentVector() {
        let climbWithDescent = [0.0, 0.0, 0.0, 0.0, 0.0, 100.0, 100.0, 100.0, 100.0, 100.0]

        XCTAssertEqual(RideMetrics.elevationGainMeters(from: elevationPoints(climbWithDescent)) ?? -1, 100, accuracy: 0.001)
    }

    /// The case the three original vectors missed, and why this returned 0 for every real ride: a
    /// climb gentle enough that no *pair of consecutive samples* clears the noise floor. 100 m over
    /// 600 samples is 1 Hz logging on a ten-minute climb, about 0.17 m per sample. Tolerance is one
    /// noise floor — a real bound, since hysteresis never banks the final partial climb.
    func testElevationGainKeepsAGradualRealWorldClimb() {
        let gradual: [Double] = (0..<600).map { index in Double(index) * (100.0 / 599.0) }

        XCTAssertEqual(RideMetrics.elevationGainMeters(from: elevationPoints(gradual)) ?? -1, 100, accuracy: 2)
    }

    func testElevationGainReportsClimbNotJitterOnAGradualAscent() {
        let jittery: [Double] = (0..<600).map { index in
            let ramp: Double = Double(index) * (100.0 / 599.0)
            let jitter: Double = index % 2 == 0 ? 0.6 : -0.6
            return ramp + jitter
        }

        XCTAssertEqual(RideMetrics.elevationGainMeters(from: elevationPoints(jittery)) ?? -1, 100, accuracy: 2)
    }

    /// Total ascent, not net: down 50 then up 50 is 50 m of climbing on the way back up.
    func testElevationGainCountsAReAscentOfTheSameHill() {
        let plateau: [Double] = Array(repeating: 50.0, count: 200)
        let descent: [Double] = (0..<200).map { index in 50.0 - Double(index) * (50.0 / 199.0) }
        let ascent: [Double] = (0..<200).map { index in Double(index) * (50.0 / 199.0) }
        let upDownUp: [Double] = plateau + descent + ascent

        XCTAssertEqual(RideMetrics.elevationGainMeters(from: elevationPoints(upDownUp)) ?? -1, 50, accuracy: 2)
    }

    /// Zero here is a fact — the ride was flat — and is distinct from "no altitude data", which is
    /// nil and renders no cell at all (§5.2).
    func testElevationGainReportsZeroForAFlatRideRatherThanNil() {
        XCTAssertEqual(
            RideMetrics.elevationGainMeters(from: elevationPoints(Array(repeating: 800.0, count: 50))) ?? -1,
            0,
            accuracy: 0.001
        )
    }

    func testAverageSpeedGuardsZeroAndNegativeDuration() {
        XCTAssertEqual(HistoryRideMetrics.averageSpeedKmh(distanceKm: 10, duration: 1_800), 20.0, accuracy: 0.001)
        XCTAssertEqual(HistoryRideMetrics.averageSpeedKmh(distanceKm: 10, duration: 0), 0)
        XCTAssertEqual(HistoryRideMetrics.averageSpeedKmh(distanceKm: 10, duration: -1), 0)
    }

    private func elevationPoints(_ altitudes: [Double]) -> [GPSPoint] {
        altitudes.enumerated().map { index, altitude in
            GPSPoint(
                latitude: 0,
                longitude: Double(index) / 10_000,
                altitude: altitude,
                accuracy: 5,
                speed: 1,
                timestamp: Date(timeIntervalSince1970: Double(index))
            )
        }
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
