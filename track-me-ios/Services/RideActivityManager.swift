import Foundation
import ActivityKit

/// Owns the Live Activity lifecycle for an active ride. Deliberately free of
/// SwiftData/Firestore/CoreLocation — it takes plain values, so a Live Activity
/// failure can never affect tracking.
///
/// ActivityKit enforces an update budget; updates are throttled to at most one
/// per ~15 s or per 25 m of distance, except state transitions which push
/// immediately (via `force`). Duration is rendered by the widget's auto-ticking
/// timer, so it stays correct between updates.
@MainActor
final class RideActivityManager {
    static let shared = RideActivityManager()
    private init() {}

    private var activity: Activity<RideActivityAttributes>?
    private var lastUpdate = Date.distantPast
    private var lastDistanceMeters = 0.0

    private let minUpdateInterval: TimeInterval = 15
    private let minDistanceDelta = 25.0
    private let staleAfter: TimeInterval = 60

    func startActivity(rideId: String, startedAt: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard activity == nil else { return }

        let state = RideActivityAttributes.ContentState(
            startedAt: startedAt, distanceMeters: 0, speedMps: 0,
            isPaused: false, isGpsLost: false, pausedElapsed: 0
        )
        do {
            activity = try Activity.request(
                attributes: RideActivityAttributes(rideId: rideId),
                content: .init(state: state, staleDate: Date().addingTimeInterval(staleAfter))
            )
            lastUpdate = Date()
            lastDistanceMeters = 0
        } catch {
            // Rate-limited / disabled — tracking continues unaffected.
            NSLog("TrackMe: Live Activity start failed: %@", error.localizedDescription)
        }
    }

    /// `force` for immediate state transitions (pause/resume/gps-lost/restored).
    func update(startedAt: Date, distanceMeters: Double, speedMps: Double,
                isPaused: Bool, isGpsLost: Bool, pausedElapsed: TimeInterval,
                force: Bool = false) {
        guard let activity else { return }

        let now = Date()
        let enoughTime = now.timeIntervalSince(lastUpdate) >= minUpdateInterval
        let enoughDistance = abs(distanceMeters - lastDistanceMeters) >= minDistanceDelta
        guard force || enoughTime || enoughDistance else { return }

        lastUpdate = now
        lastDistanceMeters = distanceMeters
        let state = RideActivityAttributes.ContentState(
            startedAt: startedAt, distanceMeters: distanceMeters, speedMps: speedMps,
            isPaused: isPaused, isGpsLost: isGpsLost, pausedElapsed: pausedElapsed
        )
        Task {
            await activity.update(.init(state: state, staleDate: now.addingTimeInterval(staleAfter)))
        }
    }

    func end(startedAt: Date, distanceMeters: Double, speedMps: Double, pausedElapsed: TimeInterval) {
        guard let ending = activity else { return }
        activity = nil
        let finalState = RideActivityAttributes.ContentState(
            startedAt: startedAt, distanceMeters: distanceMeters, speedMps: speedMps,
            isPaused: false, isGpsLost: false, pausedElapsed: pausedElapsed
        )
        Task {
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
}
