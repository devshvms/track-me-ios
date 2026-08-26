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
        var maxSpeedMps = nonNegativeFinite(sorted[0].speed)

        for (previous, current) in zip(sorted, sorted.dropFirst()) {
            maxSpeedMps = max(maxSpeedMps, nonNegativeFinite(current.speed))
            guard !previous.isPaused, !current.isPaused else { continue }

            distanceMeters += distance(from: previous, to: current)
            let intervalMillis = Int64(current.timestamp.timeIntervalSince(previous.timestamp) * 1_000)
            if intervalMillis > 0, intervalMillis <= 60_000 {
                movingDurationMillis += intervalMillis
            }
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
        return zip(smoothed, smoothed.dropFirst()).reduce(0) { total, pair in
            let delta = pair.1 - pair.0
            return total + (delta >= 2 ? delta : 0)
        }
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
        return zip(smoothed, smoothed.dropFirst()).reduce(0) { total, pair in
            let delta = pair.1 - pair.0
            return total + (delta >= 2 ? delta : 0)
        }
    }
}
