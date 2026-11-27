import CoreLocation
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
    let rideId: UUID
    let endTime: Date
    let distanceMeters: Double
    let activeDurationMillis: Int64
    let qualifiesForStats: Bool

    init(
        rideId: UUID = UUID(),
        endTime: Date,
        distanceMeters: Double,
        activeDurationMillis: Int64 = 0,
        qualifiesForStats: Bool = false
    ) {
        self.rideId = rideId
        self.endTime = endTime
        self.distanceMeters = distanceMeters
        self.activeDurationMillis = activeDurationMillis
        self.qualifiesForStats = qualifiesForStats
    }
}

struct TrailingDwellCutoff: Equatable {
    let keepEndIndexInclusive: Int
    let cutoffTimestamp: Date
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
    private static let dwellAnchorRadiusMeters = 75.0
    private static let stationarySpeedThresholdMps = 1.0 // 3.6 km/h
    private static let trailDwellPruneMinSeconds: TimeInterval = 10 * 60
    private static let minPreDwellMovementMeters = 100.0

    /// TASK-385: Identifies a trailing stationary cluster (>= 10 min within 75m and <= 3.6 km/h)
    /// following real movement (>= 100m), so recovered rides dropped indoors don't preserve hours
    /// of stationary tail. Parity with Android `OrphanedRideRecoveryManager.findTrailingDwellCutoff`.
    static func trailingDwellCutoff(for sortedPoints: [GPSPoint]) -> TrailingDwellCutoff? {
        guard sortedPoints.count >= 2 else { return nil }
        let tailAnchor = sortedPoints[sortedPoints.count - 1]
        let anchorLoc = CLLocation(latitude: tailAnchor.latitude, longitude: tailAnchor.longitude)
        var tailStartIdx = sortedPoints.count - 1
        while tailStartIdx > 0 {
            let prev = sortedPoints[tailStartIdx - 1]
            let prevLoc = CLLocation(latitude: prev.latitude, longitude: prev.longitude)
            if anchorLoc.distance(from: prevLoc) <= dwellAnchorRadiusMeters
                && prev.speed <= stationarySpeedThresholdMps {
                tailStartIdx -= 1
            } else {
                break
            }
        }
        guard tailStartIdx > 0 && tailStartIdx < sortedPoints.count - 1 else { return nil }
        guard tailAnchor.timestamp.timeIntervalSince(sortedPoints[tailStartIdx].timestamp) >= trailDwellPruneMinSeconds else {
            return nil
        }

        var preDwellDistance = 0.0
        for idx in 1...tailStartIdx {
            let prev = sortedPoints[idx - 1]
            let curr = sortedPoints[idx]
            preDwellDistance += CLLocation(latitude: prev.latitude, longitude: prev.longitude)
                .distance(from: CLLocation(latitude: curr.latitude, longitude: curr.longitude))
        }
        guard preDwellDistance >= minPreDwellMovementMeters else { return nil }
        return TrailingDwellCutoff(
            keepEndIndexInclusive: tailStartIdx,
            cutoffTimestamp: sortedPoints[tailStartIdx].timestamp
        )
    }

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
            // TASK-356: make rescued rides visible to PostHog (coarse counts only).
            TelemetryManager.shared.trackRideRecovered(
                recoveredCount: summary.recoveredCount,
                discardedCount: summary.discardedCount,
                totalMeters: summary.recovered.reduce(0) { $0 + $1.distanceMeters }
            )
        }
        if let message = toastMessage(for: summary) {
            ToastManager.shared.show(message: message, style: .info)
        }
        // §6.1.1 scenario 1. The toast above only exists if the app is open, and the people who
        // most need this are the ones whose phone died and have stopped expecting the ride to be
        // there. Class A — never rationed by the proactive budget.
        await RecoveryNotifier.notify(summary: summary)
        // §6.1.7: one row per recovered ride. The notification says "3 rides were saved" because
        // it has one line; the feed has room to say which three, and checking whether a particular
        // ride survived is the reason to look.
        await MainActor.run {
            BulletinAdapters.from(summary).forEach { BulletinStore.shared.add($0) }
        }
        // TASK-385: Credit qualifying rescued rides idempotently in RideStatsStore + RevealCoordinator.
        await creditRecoveredRides(summary: summary, container: container)
    }

    /// TASK-385: Folds qualifying recovered rides idempotently into `RideStatsStore` and stages
    /// the earned reveal / streak transition once per ride ID.
    static func creditRecoveredRides(
        summary: RecoverySummary,
        container: ModelContainer? = nil,
        statsStore: RideStatsStore = .shared,
        onNewCredit: Bool = true
    ) async {
        var didCreditNewRide = false
        for ride in summary.recovered where ride.qualifiesForStats {
            let summaryFact = GoodRideSummary(
                rideId: ride.rideId.uuidString,
                finishedAtMillis: Int64(ride.endTime.timeIntervalSince1970 * 1000),
                durationMillis: ride.activeDurationMillis,
                distanceMeters: ride.distanceMeters
            )
            let transition = await statsStore.recordGoodRide(summaryFact)
            guard !transition.alreadyProcessed else { continue }
            didCreditNewRide = true
            let reveal = RevealSelector.select(transition)
            if onNewCredit {
                await MainActor.run {
                    if let reveal {
                        RevealCoordinator.shared.put(reveal)
                        if container != nil {
                            DataRepository.shared.recordEarnedReveal(
                                rideId: ride.rideId,
                                kind: reveal.kind,
                                previousBest: RevealSelector.previousBest(for: reveal.kind, in: transition),
                                milestoneCount: reveal.milestoneRideCount
                            )
                        }
                    }
                    if transition.isFirstRideOfWeek {
                        TelemetryManager.shared.trackWeeklyStreakUpdated(
                            streakWeeks: transition.streakWeeks,
                            froze: transition.streakFroze
                        )
                    }
                }
            }
        }
        if didCreditNewRide && onNewCredit {
            await WeeklyRecapScheduler.refresh()
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

            let sortedPoints = (ride.points ?? []).sorted { $0.timestamp < $1.timestamp }
            guard !sortedPoints.isEmpty else {
                // No usable data — a ride that died in its first seconds.
                context.delete(ride)
                summary.discardedCount += 1
                continue
            }

            var points = sortedPoints
            var wasDwellPruned = false
            if let cutoff = trailingDwellCutoff(for: sortedPoints),
               cutoff.cutoffTimestamp > ride.startTime {
                for tailPoint in sortedPoints[(cutoff.keepEndIndexInclusive + 1)...] {
                    context.delete(tailPoint)
                }
                points = Array(sortedPoints[...cutoff.keepEndIndexInclusive])
                ride.points = points
                wasDwellPruned = true
            }
            guard let lastPoint = points.last else { continue }

            // The ride ended when movement stopped / the phone died, not now.
            ride.endTime = lastPoint.timestamp
            if wasDwellPruned || ride.trackingAlgorithmVersion != 2 || !ride.hasCompleteAggregate {
                ride.applyAggregate(RideMetrics.reconstructed(from: points))
            }
            let recoveredIntervals = LiveShareIntervalTracker().finalizeIntervals(
                for: ride.id,
                endedAt: lastPoint.timestamp
            )
            if !recoveredIntervals.isEmpty {
                let startMs = Int64((ride.startTime.timeIntervalSince1970 * 1_000.0).rounded())
                let endMs = Int64((lastPoint.timestamp.timeIntervalSince1970 * 1_000.0).rounded())
                ride.isBroadcasted = true
                ride.liveShareIntervalsJson = LiveShareIntervals.serialize(recoveredIntervals)
                ride.liveShareMode = LiveShareIntervals.resolveMode(
                    rideStartMillis: startMs,
                    rideEndMillis: endMs,
                    intervals: recoveredIntervals
                )
            }
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
                    rideId: ride.id,
                    endTime: lastPoint.timestamp,
                    distanceMeters: ride.distanceMeters ?? 0,
                    activeDurationMillis: ride.movingDurationMillis ?? 0,
                    qualifiesForStats: ride.qualifiesForStats
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
