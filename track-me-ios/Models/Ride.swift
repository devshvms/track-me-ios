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
    
    // Persisted ride aggregates (parity with Android PostRideCalculation).
    // Populated at finalize from the live-tracked totals; nil only for legacy
    // rides not yet backfilled (see RideAggregateBackfill).
    var distanceMeters: Double?
    var movingDurationMillis: Int?
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
    /// Distance in km for display. Uses the persisted aggregate when present;
    /// falls back to a live re-computation for un-backfilled legacy rides only.
    var displayDistanceKm: Double {
        if let m = distanceMeters { return m / 1000.0 }
        return RideMetrics.rawDistanceMeters(points ?? []) / 1000.0
    }
}
