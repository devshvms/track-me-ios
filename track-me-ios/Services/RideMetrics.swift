import CoreLocation
import Foundation
import SwiftData
import os

struct RideAggregateSnapshot: Equatable {
    let distanceMeters: Double
    let movingDurationMillis: Int64
    let maxSpeedMps: Double
    let avgSpeedMps: Double
    let pointCount: Int

    static func live(
        distanceMeters: Double,
        movingDurationMillis: TimeInterval,
        maxSpeedMps: Double,
        pointCount: Int
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
            pointCount: max(0, pointCount)
        )
    }
}

enum RideMetrics {
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
                pointCount: 0
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
            pointCount: sorted.count
        )
    }

    nonisolated static func nonNegativeFinite(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }

    private static func distance(from first: GPSPoint, to second: GPSPoint) -> Double {
        CLLocation(latitude: first.latitude, longitude: first.longitude)
            .distance(from: CLLocation(latitude: second.latitude, longitude: second.longitude))
    }
}

@MainActor
enum RideAggregateBackfill {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "in.shvms.track-me-ios",
        category: "RideAggregateBackfill"
    )
    private static var didRun = false

    static func run(container: ModelContainer) {
        guard !didRun else { return }
        didRun = true

        let context = ModelContext(container)
        do {
            let rides = try context.fetch(FetchDescriptor<Ride>())
            var changed = 0
            for ride in rides where ride.endTime != nil && !ride.hasCompleteAggregate {
                ride.applyAggregate(RideMetrics.reconstructed(from: ride.points ?? []))
                ride.isSynced = false
                changed += 1
            }
            guard changed > 0 else { return }
            try context.save()
            logger.info("Backfilled aggregates for \(changed) rides")
        } catch {
            logger.error("Aggregate backfill failed: \(error.localizedDescription)")
        }
    }
}
