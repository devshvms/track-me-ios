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
    /// Keeps a cloud delete durable until its batch is acknowledged. This is
    /// deliberately local-only: the uploader must not resurrect a ride while
    /// its deletion is queued (scope 1.7.3 §2, client-side cascade).
    var pendingDelete: Bool = false
    var firestoreId: String?
    /// The last committed cloud shape. It lets an offline delete reconstruct
    /// the child path without fetching the parent first.
    var cloudChunkCount: Int?
    var title: String?
    var persona: String = "AUTO"
    /// Local first-run fixture. It behaves like a ride in History but never syncs or counts.
    var isSample: Bool = false
    /// IANA timezone captured when recording starts. Legacy/imported rows stay nil and retain the
    /// shipped read-time fallback to the device timezone.
    var startZoneId: String?

    // Finalized, filtered metrics. Optional fields keep the SwiftData migration
    // additive for rides recorded before aggregate persistence was introduced.
    var distanceMeters: Double?
    var movingDurationMillis: Int64?
    var maxSpeedMps: Double?
    var avgSpeedMps: Double?
    var pointCount: Int?
    var elevationGainMeters: Double? = nil
    /// Persisted dashboard qualification; the metadata version distinguishes a reconciled false
    /// from a legacy row that has not been inspected yet.
    var qualifiesForStats: Bool = false
    var dashboardMetadataVersion: Int = 0
    /// TASK-246: the History card's route shape, so the list projection can draw a real route
    /// without fetching `points`. Optional with a default, so SwiftData migrates additively.
    var routePolyline: String? = nil
    /// TASK-232: this ride was recorded while a group session was live.
    ///
    /// The marker and the count below are deliberately the *whole* record.
    /// `COMMUNITY_REDESIGN_SPEC` §2.2 allows a count and nothing else — no group id, no roster, no
    /// names — because a count is not identities and the promise printed on that screen is that
    /// nothing about the other riders is saved. Neither field is synced: `FirestoreSyncManager`
    /// writes an explicit field map and these are not in it, so no new Data Safety surface (§5.4).
    /// Additive and defaulted, so the SwiftData migration stays lightweight.
    var wasGroupRide: Bool = false
    /// How many riders were in the group, including this one. Nil when it was never observed —
    /// §5.5's honesty rule: an unknown count renders no count, never `0`.
    var groupRiderCount: Int?
    
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
                pointCount: max(0, pointCount),
                elevationGainMeters: elevationGainMeters
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
            pointCount: max(0, pointCount ?? fallback.pointCount),
            elevationGainMeters: elevationGainMeters ?? fallback.elevationGainMeters
        )
    }

    var displayDistanceKm: Double { aggregateSnapshot.distanceMeters / 1_000 }

    func applyAggregate(_ aggregate: RideAggregateSnapshot) {
        distanceMeters = aggregate.distanceMeters
        movingDurationMillis = aggregate.movingDurationMillis
        maxSpeedMps = aggregate.maxSpeedMps
        avgSpeedMps = aggregate.avgSpeedMps
        pointCount = aggregate.pointCount
        elevationGainMeters = aggregate.elevationGainMeters
    }
}
