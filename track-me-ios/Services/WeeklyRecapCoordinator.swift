import Foundation

/// B2 foreground coordinator (iOS). Queried from the `scenePhase` trigger; asks the store
/// whether a completed week is worth recapping and holds it for the recap sheet. Parity with
/// Android's `TrackMeApp.checkWeeklyRecap()`. Acknowledgement happens only after the sheet is
/// actually presented, so a foreground race never loses the recap.
@Observable
@MainActor
final class WeeklyRecapCoordinator {
    static let shared = WeeklyRecapCoordinator()

    /// The recap awaiting presentation, or nil.
    var pending: WeeklyRecap?
    private var lastPresentedWeek: Int?
    private var lastTelemetryWeek: Int?

    private init() {}

    /// Ask the store for a pending recap (idempotent while one is already queued). Suppressed
    /// while a post-ride reveal is pending, so the two celebrations never stack.
    func check() async {
        guard pending == nil, RevealCoordinator.shared.pending == nil else { return }
        pending = await RideStatsStore.shared.pendingWeeklyRecap()
        if let recap = pending {
            lastPresentedWeek = recap.weekStartEpochDay
            if lastTelemetryWeek != recap.weekStartEpochDay {
                lastTelemetryWeek = recap.weekStartEpochDay
                TelemetryManager.shared.trackWeeklyRecapShown(weekKey: recap.weekKey, rideCount: recap.rideCount, distanceKm: recap.distanceMeters / 1000.0)
            }
        }
    }

    /// Acknowledge the recap after it has been presented (dedupe by week).
    func acknowledge(weekStartEpochDay: Int? = nil) async {
        guard let week = weekStartEpochDay ?? pending?.weekStartEpochDay ?? lastPresentedWeek else { return }
        pending = nil
        lastPresentedWeek = nil
        await RideStatsStore.shared.acknowledgeWeeklyRecap(weekStartEpochDay: week)
    }
}
