import CoreLocation
import Foundation
import SwiftData

nonisolated struct RideAggregateSnapshot: Equatable {
    let distanceMeters: Double
    let movingDurationMillis: Int64
    let maxSpeedMps: Double
    let avgSpeedMps: Double
    let pointCount: Int
    let elevationGainMeters: Double?

    static func live(
        distanceMeters: Double,
        movingDurationMillis: TimeInterval,
        maxSpeedMps: Double,
        pointCount: Int,
        elevationGainMeters: Double? = nil
    ) -> RideAggregateSnapshot {
        let distance = RideMetrics.nonNegativeFinite(distanceMeters)
        let duration = Int64(max(0, movingDurationMillis.rounded()))
        let maxSpeed = RideMetrics.nonNegativeFinite(maxSpeedMps)
        let average = duration > 0 ? distance / (Double(duration) / 1_000) : 0
        return RideAggregateSnapshot(
            distanceMeters: distance,
            movingDurationMillis: duration,
            maxSpeedMps: maxSpeed,
            avgSpeedMps: average,
            pointCount: max(0, pointCount),
            elevationGainMeters: elevationGainMeters
        )
    }
}

nonisolated enum RideMetrics {
    /// Route geometry distance. This intentionally includes every segment and is
    /// appropriate for charts, not as the source of truth for a finalized ride.
    static func rawDistanceMeters(_ points: [GPSPoint]) -> Double {
        let sorted = points.sorted { $0.timestamp < $1.timestamp }
        guard sorted.count > 1 else { return 0 }

        return zip(sorted, sorted.dropFirst()).reduce(0) { total, pair in
            total + distance(from: pair.0, to: pair.1)
        }
    }

    /// Reconstructs legacy/imported aggregates with Android's pause and gap rules.
    /// Normal ride finalization uses the live filtered distance instead.
    static func reconstructed(from points: [GPSPoint]) -> RideAggregateSnapshot {
        let sorted = points.sorted { $0.timestamp < $1.timestamp }
        guard !sorted.isEmpty else {
            return RideAggregateSnapshot(
                distanceMeters: 0,
                movingDurationMillis: 0,
                maxSpeedMps: 0,
                avgSpeedMps: 0,
                pointCount: 0,
                elevationGainMeters: nil
            )
        }

        var distanceMeters = 0.0
        var movingDurationMillis: Int64 = 0
        var maxSpeedMps = 0.0

        for (previous, current) in zip(sorted, sorted.dropFirst()) {
            // TASK-286: eligibility is decided ONCE and applied to distance, duration and peak
            // together.
            //
            // Distance used to be added for every unpaused pair while duration was gated on the
            // gap threshold, so a GPS-loss chord contributed metres with no seconds. The existing
            // vector encoded that as expected: 222.4 m against 10 s of moving time, an average of
            // 22.24 m/s beside a stored maximum of 5. Incompatible evidence in one aggregate is
            // source corruption, not a presentation defect — no clamp downstream can repair it,
            // because the distance itself was never travelled in the time recorded.
            //
            // TASK-259's threshold reasoning is unchanged and now simply governs both halves: 25s
            // is what this app already *calls* a GPS signal gap, the number behind the count in
            // Recording details and behind TASK-257's dotted segments. A stretch reported to a
            // rider as a gap is not time they moved — and it is not distance they covered either.
            let intervalMillis = Int64(current.timestamp.timeIntervalSince(previous.timestamp) * 1_000)
            let isEligible = !previous.isPaused
                && !current.isPaused
                && intervalMillis > 0
                && intervalMillis <= Int64(RideGaps.gapThresholdSeconds * 1_000)
            guard isEligible else { continue }

            let segmentMeters = distance(from: previous, to: current)
            distanceMeters += segmentMeters
            movingDurationMillis += intervalMillis

            // Peak comes only from evidence inside eligible movement — the endpoints' own speed
            // readings, plus the interval's chord speed.
            //
            // The chord is observed, not invented: two recorded positions over two recorded
            // timestamps. It matters because the average below is derived from geometry while the
            // stored `speed` is a separate sensor reading, and the two can disagree. Without it a
            // ride whose GPS speeds under-read produces an average faster than its own peak — the
            // very invariant this task exists to restore, and the one TASK-285 fixed on Android.
            //
            // This is NOT max(maxSpeed, avgSpeed): that fallback is forbidden and would be
            // circular. A chord speed is a per-interval observation; the average is a
            // distance-weighted aggregate across all of them. On a variable route they differ, and
            // the maximum of the set is necessarily at least the weighted mean of the set — so the
            // invariant holds by construction rather than by clamping.
            let chordSpeed = segmentMeters / (Double(intervalMillis) / 1_000)
            maxSpeedMps = max(maxSpeedMps, nonNegativeFinite(previous.speed))
            maxSpeedMps = max(maxSpeedMps, nonNegativeFinite(current.speed))
            maxSpeedMps = max(maxSpeedMps, nonNegativeFinite(chordSpeed))
        }

        let average = movingDurationMillis > 0
            ? distanceMeters / (Double(movingDurationMillis) / 1_000)
            : 0
        return RideAggregateSnapshot(
            distanceMeters: nonNegativeFinite(distanceMeters),
            movingDurationMillis: movingDurationMillis,
            maxSpeedMps: maxSpeedMps,
            avgSpeedMps: nonNegativeFinite(average),
            pointCount: sorted.count,
            elevationGainMeters: elevationGainMeters(from: sorted)
        )
    }

    /// Computes ascent from a centered, edge-truncated five-point moving average.
    /// Fewer than ten finite altitudes are too sparse to support an elevation cell.
    static func elevationGainMeters(from points: [GPSPoint]) -> Double? {
        calculateElevationGain(points.map { ElevationSample(altitude: $0.altitude, timestamp: $0.timestamp) })
    }

    static func elevationGainMeters(fromLocations locations: [CLLocation]) -> Double? {
        calculateElevationGain(locations.map { ElevationSample(altitude: $0.altitude, timestamp: $0.timestamp) })
    }

    /// A climb banks once it stands this far above the lowest point since the last bank.
    ///
    /// **Measured against a running reference, not the previous sample.** Applying it
    /// sample-to-sample discarded any climb gentle enough that no consecutive pair cleared it --
    /// and at 1 Hz a 100 m climb over ten minutes moves about 0.17 m per sample, so every delta was
    /// thrown away and this returned exactly zero for every real ride. Matches Android's
    /// `ElevationGain.kt`, so the two platforms agree well inside §5.2's ±5% tolerance.
    private static let noiseFloorMeters = 2.0

    private static func calculateElevationGain(_ samples: [ElevationSample]) -> Double? {
        let altitudes = samples
            .filter { $0.altitude.isFinite }
            .sorted { $0.timestamp < $1.timestamp }
            .map(\.altitude)
        guard altitudes.count >= 10 else { return nil }

        let smoothed = altitudes.indices.map { index in
            let start = max(0, index - 2)
            let end = min(altitudes.count - 1, index + 2)
            return altitudes[start...end].reduce(0, +) / Double(end - start + 1)
        }
        var reference = smoothed[0]
        var gain = 0.0
        for altitude in smoothed {
            let climbed = altitude - reference
            if climbed >= noiseFloorMeters {
                gain += climbed
                reference = altitude
            } else if altitude < reference {
                // Descending resets the mark the next climb is measured from, so a descent and a
                // re-ascent of the same hill are counted once each rather than smeared into one.
                reference = altitude
            }
        }
        return gain
    }

    nonisolated static func nonNegativeFinite(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }

    private static func distance(from first: GPSPoint, to second: GPSPoint) -> Double {
        CLLocation(latitude: first.latitude, longitude: first.longitude)
            .distance(from: CLLocation(latitude: second.latitude, longitude: second.longitude))
    }

    private struct ElevationSample {
        let altitude: Double
        let timestamp: Date
    }
}
extension RideMetrics {
    static func elevationGainMeters(from points: [CLLocation]) -> Double? {
        let altitudes = points
            .filter { $0.altitude.isFinite }
            .sorted { $0.timestamp < $1.timestamp }
            .map(\.altitude)
        guard altitudes.count >= 10 else { return nil }

        let smoothed = altitudes.indices.map { index in
            let start = max(0, index - 2)
            let end = min(altitudes.count - 1, index + 2)
            return altitudes[start...end].reduce(0, +) / Double(end - start + 1)
        }
        var reference = smoothed[0]
        var gain = 0.0
        for altitude in smoothed {
            let climbed = altitude - reference
            if climbed >= noiseFloorMeters {
                gain += climbed
                reference = altitude
            } else if altitude < reference {
                // Descending resets the mark the next climb is measured from, so a descent and a
                // re-ascent of the same hill are counted once each rather than smeared into one.
                reference = altitude
            }
        }
        return gain
    }
}
