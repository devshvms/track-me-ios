import Foundation
import SwiftData

@Model
final class Ride {
    @Attribute(.unique) var id: UUID
    var startTime: Date
    var endTime: Date?
    var sourceInfo: String
    var isBroadcasted: Bool
    var isSynced: Bool
    var firestoreId: String?
    var title: String?
    var persona: String = "AUTO"

    // Finalized, filtered metrics. Optional fields keep the SwiftData migration
    // additive for rides recorded before aggregate persistence was introduced.
    var distanceMeters: Double?
    var movingDurationMillis: Int64?
    var maxSpeedMps: Double?
    var avgSpeedMps: Double?
    var pointCount: Int?
    
    @Relationship(deleteRule: .cascade, inverse: \GPSPoint.ride)
    var points: [GPSPoint]?
    
    init(id: UUID = UUID(), startTime: Date = Date(), sourceInfo: String = "iOS Device", isBroadcasted: Bool = false, isSynced: Bool = false, title: String? = nil) {
        self.id = id
        self.startTime = startTime
        self.sourceInfo = sourceInfo
        self.isBroadcasted = isBroadcasted
        self.isSynced = isSynced
        self.title = title
    }
}

extension Ride {
    var ridePersona: RidePersona { RidePersona.fromStoredName(persona) }

    var hasCompleteAggregate: Bool {
        distanceMeters != nil
            && movingDurationMillis != nil
            && maxSpeedMps != nil
            && avgSpeedMps != nil
            && pointCount != nil
    }

    var aggregateSnapshot: RideAggregateSnapshot {
        if let distanceMeters,
           let movingDurationMillis,
           let maxSpeedMps,
           let avgSpeedMps,
           let pointCount {
            return RideAggregateSnapshot(
                distanceMeters: RideMetrics.nonNegativeFinite(distanceMeters),
                movingDurationMillis: max(0, movingDurationMillis),
                maxSpeedMps: RideMetrics.nonNegativeFinite(maxSpeedMps),
                avgSpeedMps: RideMetrics.nonNegativeFinite(avgSpeedMps),
                pointCount: max(0, pointCount)
            )
        }

        let fallback = RideMetrics.reconstructed(from: points ?? [])
        let distance = distanceMeters.map(RideMetrics.nonNegativeFinite) ?? fallback.distanceMeters
        let duration = max(0, movingDurationMillis ?? fallback.movingDurationMillis)
        let average = avgSpeedMps.map(RideMetrics.nonNegativeFinite)
            ?? (duration > 0 ? distance / (Double(duration) / 1_000) : fallback.avgSpeedMps)
        return RideAggregateSnapshot(
            distanceMeters: distance,
            movingDurationMillis: duration,
            maxSpeedMps: maxSpeedMps.map(RideMetrics.nonNegativeFinite) ?? fallback.maxSpeedMps,
            avgSpeedMps: average,
            pointCount: max(0, pointCount ?? fallback.pointCount)
        )
    }

    var displayDistanceKm: Double { aggregateSnapshot.distanceMeters / 1_000 }

    func applyAggregate(_ aggregate: RideAggregateSnapshot) {
        distanceMeters = aggregate.distanceMeters
        movingDurationMillis = aggregate.movingDurationMillis
        maxSpeedMps = aggregate.maxSpeedMps
        avgSpeedMps = aggregate.avgSpeedMps
        pointCount = aggregate.pointCount
    }
}
