import Foundation
import ActivityKit

/// A coarse representation of values that are actually rendered. Group syncs
/// may arrive every ~10 seconds, but identical snapshots must not consume the
/// ActivityKit update budget.
nonisolated struct RideActivityDisplaySnapshot: Equatable {
    let distanceBucket: String
    let speedBucket: String
    let isPaused: Bool
    let isGpsLost: Bool
    let groupMemberCount: Int
    let alertSignal: RideActivityAlertSignal
    let alertMemberName: String
    let alertStatusCode: String

    init(state: RideActivityAttributes.ContentState) {
        // Use the formatter output itself as the bucket. This keeps coalescing
        // exactly aligned with what the rider sees (including locale rounding)
        // instead of silently hiding a rendered 0.01 km / 0.1 km/h change.
        distanceBucket = RideActivityFormat.distance(state)
        speedBucket = RideActivityFormat.speed(state)
        isPaused = state.isPaused
        isGpsLost = state.isGpsLost
        groupMemberCount = state.groupMemberCount
        alertSignal = state.alertSignal
        alertMemberName = state.alertMemberName
        alertStatusCode = state.alertStatusCode
    }
}

/// Pure update coalescer, kept independent of ActivityKit so a simulated sync
/// sequence can assert the exact number of emitted updates.
nonisolated struct RideActivityUpdateGate {
    private var lastSnapshot: RideActivityDisplaySnapshot?
    private var lastEmission = Date.distantPast
    let minimumMetricInterval: TimeInterval

    init(minimumMetricInterval: TimeInterval = 15) {
        self.minimumMetricInterval = minimumMetricInterval
    }

    mutating func seed(_ snapshot: RideActivityDisplaySnapshot, at date: Date) {
        lastSnapshot = snapshot
        lastEmission = date
    }

    mutating func shouldEmit(
        _ snapshot: RideActivityDisplaySnapshot,
        at date: Date,
        force: Bool = false
    ) -> Bool {
        guard let previous = lastSnapshot else {
            seed(snapshot, at: date)
            return true
        }

        let rideStateChanged = snapshot.isPaused != previous.isPaused ||
            snapshot.isGpsLost != previous.isGpsLost
        let groupPresentationChanged = snapshot.groupMemberCount != previous.groupMemberCount ||
            snapshot.alertSignal != previous.alertSignal ||
            snapshot.alertMemberName != previous.alertMemberName ||
            snapshot.alertStatusCode != previous.alertStatusCode
        let metricBucketChanged = snapshot.distanceBucket != previous.distanceBucket ||
            snapshot.speedBucket != previous.speedBucket
        let metricBudgetAvailable = date.timeIntervalSince(lastEmission) >= minimumMetricInterval

        guard force || rideStateChanged || groupPresentationChanged ||
                (metricBucketChanged && metricBudgetAvailable) else { return false }
        seed(snapshot, at: date)
        return true
    }

    mutating func reset() {
        lastSnapshot = nil
        lastEmission = .distantPast
    }
}

/// Owns the Live Activity lifecycle for an active ride. Deliberately free of
/// SwiftData/Firestore/CoreLocation — it takes plain values, so a Live Activity
/// failure can never affect tracking.
///
/// ActivityKit enforces an update budget; metric changes are coalesced into
/// display buckets and held to at most one update per ~15 s. Ride-state and
/// aggregate group-presentation changes push immediately. Duration is rendered
/// by the widget's auto-ticking timer, so it stays correct between updates.
@MainActor
final class RideActivityManager {
    static let shared = RideActivityManager()
    private init() {}

    private var activity: Activity<RideActivityAttributes>?
    private var latestContentState: RideActivityAttributes.ContentState?
    private var updateGate = RideActivityUpdateGate()
    private var updateTask: Task<Void, Never>?
    private var groupPresentation = GroupPresentation.empty

    private let staleAfter: TimeInterval = 60

    private struct GroupPresentation: Equatable {
        var memberCount: Int
        var alertSignal: RideActivityAlertSignal
        var memberName: String
        var statusCode: String

        static let empty = GroupPresentation(
            memberCount: 0,
            alertSignal: .none,
            memberName: "",
            statusCode: ""
        )
    }

    func startActivity(rideId: String, startedAt: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard activity == nil else { return }

        let state = contentState(
            startedAt: startedAt,
            distanceMeters: 0,
            speedMps: 0,
            isPaused: false,
            isGpsLost: false,
            pausedElapsed: 0
        )
        do {
            activity = try Activity.request(
                attributes: RideActivityAttributes(rideId: rideId),
                content: .init(state: state, staleDate: Date().addingTimeInterval(staleAfter))
            )
            let now = Date()
            latestContentState = state
            updateGate.seed(.init(state: state), at: now)
        } catch {
            // Rate-limited / disabled — tracking continues unaffected.
            NSLog("TrackMe: Live Activity start failed: %@", error.localizedDescription)
        }
    }

    /// `force` for immediate state transitions (pause/resume/gps-lost/restored).
    func update(startedAt: Date, distanceMeters: Double, speedMps: Double,
                isPaused: Bool, isGpsLost: Bool, pausedElapsed: TimeInterval,
                force: Bool = false) {
        guard activity != nil else { return }

        let state = contentState(
            startedAt: startedAt,
            distanceMeters: distanceMeters,
            speedMps: speedMps,
            isPaused: isPaused,
            isGpsLost: isGpsLost,
            pausedElapsed: pausedElapsed
        )
        emitIfNeeded(state, force: force)
    }

    /// Called from the existing severity-1 alert coordinator. Repeated group
    /// syncs pass through this method, but only a count/signal/content change
    /// crosses the update gate.
    func updateGroupPresentation(
        memberCount: Int,
        alertSignal: RideActivityAlertSignal,
        memberName: String = "",
        statusCode: String = ""
    ) {
        groupPresentation = GroupPresentation(
            memberCount: max(0, memberCount),
            alertSignal: alertSignal,
            memberName: alertSignal == .raised ? memberName : "",
            statusCode: alertSignal == .raised ? statusCode : ""
        )
        guard let latest = latestContentState else { return }
        emitIfNeeded(contentState(copying: latest))
    }

    func clearGroupPresentation() {
        guard groupPresentation != .empty else { return }
        groupPresentation = .empty
        guard let latest = latestContentState else { return }
        emitIfNeeded(contentState(copying: latest))
    }

    private func emitIfNeeded(
        _ state: RideActivityAttributes.ContentState,
        force: Bool = false
    ) {
        latestContentState = state
        guard let activity else { return }
        let now = Date()
        guard updateGate.shouldEmit(.init(state: state), at: now, force: force) else { return }

        let precedingUpdate = updateTask
        updateTask = Task {
            await precedingUpdate?.value
            await activity.update(
                .init(state: state, staleDate: now.addingTimeInterval(staleAfter))
            )
        }
    }

    func end(startedAt: Date, distanceMeters: Double, speedMps: Double, pausedElapsed: TimeInterval) {
        guard let ending = activity else { return }
        activity = nil
        let finalState = contentState(
            startedAt: startedAt,
            distanceMeters: distanceMeters,
            speedMps: speedMps,
            isPaused: false,
            isGpsLost: false,
            pausedElapsed: pausedElapsed
        )
        latestContentState = nil
        updateGate.reset()
        let precedingUpdate = updateTask
        updateTask = nil
        Task {
            await precedingUpdate?.value
            // Let the final stats linger briefly, then dismiss.
            await ending.end(.init(state: finalState, staleDate: nil), dismissalPolicy: .after(.now + 4))
        }
    }

    /// On launch, dismiss any Live Activity left over from a crash/force-quit
    /// whose ride is not the currently active one.
    func endOrphanedActivities(activeRideId: String?) {
        for stale in Activity<RideActivityAttributes>.activities where stale.attributes.rideId != activeRideId {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func contentState(
        startedAt: Date,
        distanceMeters: Double,
        speedMps: Double,
        isPaused: Bool,
        isGpsLost: Bool,
        pausedElapsed: TimeInterval
    ) -> RideActivityAttributes.ContentState {
        RideActivityAttributes.ContentState(
            startedAt: startedAt,
            distanceMeters: distanceMeters,
            speedMps: speedMps,
            isPaused: isPaused,
            isGpsLost: isGpsLost,
            pausedElapsed: pausedElapsed,
            groupMemberCount: groupPresentation.memberCount,
            alertSignal: groupPresentation.alertSignal,
            alertMemberName: groupPresentation.memberName,
            alertStatusCode: groupPresentation.statusCode
        )
    }

    private func contentState(
        copying state: RideActivityAttributes.ContentState
    ) -> RideActivityAttributes.ContentState {
        contentState(
            startedAt: state.startedAt,
            distanceMeters: state.distanceMeters,
            speedMps: state.speedMps,
            isPaused: state.isPaused,
            isGpsLost: state.isGpsLost,
            pausedElapsed: state.pausedElapsed
        )
    }
}
