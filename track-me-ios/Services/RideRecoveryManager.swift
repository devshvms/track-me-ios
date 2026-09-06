import Foundation
import SwiftData

/// Result of a launch-time orphan sweep.
/// The facts a recovered ride can be described with.
///
/// SCOPE_1.8.7 §6.1.1 scenario 1 needs these, not just a count. §4.2 N1 is "every notification
/// carries a fact, not a feeling": *"Your ride was saved"* on its own is the kind of line that
/// could have been written without reading the user's data. *"12.3 km, recording stopped at
/// 14:32"* could not.
struct RecoveredRide {
    let endTime: Date
    let distanceMeters: Double
}

struct RecoverySummary {
    var recoveredCount: Int = 0
    var discardedCount: Int = 0
    /// Details of what was recovered. Deliberately carries no title: a ride title can be
    /// user-written, and a notification renders on a lock screen where whoever is holding the phone
    /// may not be its owner.
    var recovered: [RecoveredRide] = []
}

/// The default ride title ("Morning Run", "Evening Motorbike Ride", etc.). Shared
/// by normal finalization, migration, and crash recovery so selected personas can
/// never be relabeled from inferred speed. Titles are stored data, deliberately
/// not localized.
enum RideTitleGenerator {
    /// Legacy AUTO inference entry point retained for recovered/imported data tests.
    static func make(startTime: Date, points: [GPSPoint]) -> String {
        let maxSpeedKmh = (points.map(\.speed).max() ?? 0) * 3.6
        return make(startTime: startTime, persona: .auto, maxSpeedKmh: maxSpeedKmh)
    }

    static func make(startTime: Date, persona: RidePersona, points: [GPSPoint]) -> String {
        let maxSpeedKmh = points.map(\.speed).max().map { $0 * 3.6 }
        return make(startTime: startTime, persona: persona, maxSpeedKmh: maxSpeedKmh)
    }

    static func make(startTime: Date, persona: RidePersona, maxSpeedKmh: Double?) -> String {
        let activity: String
        switch persona {
        case .walk: activity = "Walk"
        case .run: activity = "Run"
        case .cycling: activity = "Cycling Ride"
        case .bikeDrive: activity = "Motorbike Ride"
        case .carDrive: activity = "Car Drive"
        case .auto:
            guard let maxSpeedKmh else {
                activity = "Ride"
                break
            }
            activity = maxSpeedKmh > 15.0 ? "Bike Ride" : "Walk/Run"
        }

        return "\(timeOfDay(for: startTime)) \(activity)"
    }

    static func isGeneratedTitle(_ title: String?) -> Bool {
        guard let title, !title.isEmpty else { return true }
        let periods = ["Morning", "Afternoon", "Evening", "Night"]
        let activities = [
            "Ride", "Bike Ride", "Walk/Run", "Walk", "Run", "Cycling",
            "Cycling Ride", "BikeDrive", "CarDrive", "Motorbike",
            "Motorbike Ride", "Car", "Car Drive"
        ]
        return periods.contains { period in
            activities.contains { title == "\(period) \($0)" }
        }
    }

    private static func timeOfDay(for startTime: Date) -> String {
        let hour = Calendar.current.component(.hour, from: startTime)
        switch hour {
        case 5...11: return "Morning"
        case 12...16: return "Afternoon"
        case 17...20: return "Evening"
        default: return "Night"
        }
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
        if summary.recoveredCount > 0 || summary.discardedCount > 0 {
            await MainActor.run {
                HomeDashboardRepository.shared.invalidate()
            }
        }
        if let message = toastMessage(for: summary) {
            ToastManager.shared.show(message: message, style: .info)
        }
        // §6.1.1 scenario 1. The toast above only exists if the app is open, and the people who
        // most need this are the ones whose phone died and have stopped expecting the ride to be
        // there. Class A — never rationed by the proactive budget.
        await RecoveryNotifier.notify(summary: summary)
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
            ride.applyAggregate(RideMetrics.reconstructed(from: points))
            ride.refreshDashboardMetadata()
            if RideTitleGenerator.isGeneratedTitle(ride.title) {
                ride.title = RideTitleGenerator.make(
                    startTime: ride.startTime,
                    persona: ride.ridePersona,
                    points: points
                )
            }
            summary.recoveredCount += 1
            summary.recovered.append(
                RecoveredRide(
                    endTime: lastPoint.timestamp,
                    distanceMeters: ride.distanceMeters ?? 0
                )
            )

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
