import Foundation
import SwiftData

/// Result of a launch-time orphan sweep.
struct RecoverySummary {
    var recoveredCount: Int = 0
    var discardedCount: Int = 0
}

/// The default ride title ("Morning Bike Ride" etc.). Shared by both the normal
/// finish path (`DataRepository.finishRide`) and crash recovery so the two can
/// never drift apart. Titles are stored data, deliberately not localized.
enum RideTitleGenerator {
    static func make(startTime: Date, points: [GPSPoint]) -> String {
        let maxSpeed = points.map(\.speed).max() ?? 0
        let maxSpeedKmh = maxSpeed * 3.6
        let activity = maxSpeedKmh > 15.0 ? "Bike Ride" : "Walk/Run"

        let hour = Calendar.current.component(.hour, from: startTime)
        let timeOfDay: String
        switch hour {
        case 5...11: timeOfDay = "Morning"
        case 12...16: timeOfDay = "Afternoon"
        case 17...20: timeOfDay = "Evening"
        default: timeOfDay = "Night"
        }
        return "\(timeOfDay) \(activity)"
    }
}

/// Finalizes rides that were left unfinished by an app kill/crash/battery death.
/// Mirrors Android's `OrphanedRideRecoveryManager`: any ride with `endTime == nil`
/// (other than the currently active one) is either finalized from its persisted
/// points or, if it has none, discarded.
enum RideRecoveryManager {
    private static var didRunLaunchRecovery = false

    /// Runs once per process launch: first give `TrackingManager` a chance to
    /// resume a still-fresh session, then finalize/discard everything else.
    static func runLaunchRecovery(container: ModelContainer) async {
        guard !didRunLaunchRecovery else { return }
        didRunLaunchRecovery = true

        // Part B first — a resumable session must not be finalized out from under
        // the user by the Part A sweep.
        await TrackingManager.shared.restoreInterruptedSessionIfNeeded(container: container)

        let summary = recoverOrphanedRides(
            container: container,
            activeRideId: TrackingManager.shared.currentRideId
        )
        if let message = toastMessage(for: summary) {
            ToastManager.shared.show(message: message, style: .info)
        }
    }

    /// Part A — the orphan sweep.
    static func recoverOrphanedRides(container: ModelContainer, activeRideId: UUID?) -> RecoverySummary {
        let context = ModelContext(container)

        // Ride counts are small; fetch all and filter in memory to sidestep any
        // `#Predicate` optional-nil quirks across SwiftData versions.
        let all = (try? context.fetch(FetchDescriptor<Ride>())) ?? []
        var summary = RecoverySummary()

        for ride in all where ride.endTime == nil {
            if ride.id == activeRideId { continue }

            let points = (ride.points ?? []).sorted { $0.timestamp < $1.timestamp }
            guard let lastPoint = points.last else {
                // No usable data — a ride that died in its first seconds.
                context.delete(ride)
                summary.discardedCount += 1
                continue
            }

            // The ride ended when the phone died, not now.
            ride.endTime = lastPoint.timestamp
            
            let distance = RideMetrics.rawDistanceMeters(points)
            let durationMillis = Int(lastPoint.timestamp.timeIntervalSince(ride.startTime) * 1000)
            let maxSpeed = points.map { $0.speed }.max() ?? 0.0
            let avgSpeed = durationMillis > 0 ? distance / (Double(durationMillis) / 1000.0) : 0.0
            
            ride.distanceMeters = distance
            ride.movingDurationMillis = durationMillis
            ride.pointCount = points.count
            ride.maxSpeedMps = maxSpeed
            ride.avgSpeedMps = avgSpeed
            
            if ride.title == nil || ride.title?.isEmpty == true {
                ride.title = RideTitleGenerator.make(startTime: ride.startTime, points: points)
            }
            summary.recoveredCount += 1

            // Fire-and-forget cloud sync, same as the normal finish path.
            FirestoreSyncManager.shared.syncRide(ride)
        }

        if summary.recoveredCount > 0 || summary.discardedCount > 0 {
            try? context.save()
        }
        return summary
    }

    /// Localized summary toast; `nil` when there was nothing to report.
    static func toastMessage(for summary: RecoverySummary) -> String? {
        switch (summary.recoveredCount, summary.discardedCount) {
        case (0, 0):
            return nil
        case let (recovered, 0):
            return recovered == 1
                ? LocalizationHelper.localized("1 interrupted ride was recovered")
                : LocalizationHelper.formatted("%@ interrupted rides were recovered", String(recovered))
        case let (0, discarded):
            return discarded == 1
                ? LocalizationHelper.localized("Removed 1 empty interrupted ride")
                : LocalizationHelper.formatted("Removed %@ empty interrupted rides", String(discarded))
        case let (recovered, discarded):
            return LocalizationHelper.formatted(
                "Recovered %1$@ interrupted, removed %2$@ empty",
                String(recovered), String(discarded)
            )
        }
    }
}
