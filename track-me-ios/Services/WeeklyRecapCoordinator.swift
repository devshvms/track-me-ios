import Foundation

/// Pure gate (TASK-119): may a *non-urgent celebration* surface interrupt the user right now?
///
/// Byte-for-byte parity with Android `domain/stats/CalmMomentGate.kt`. Prompt 09
/// (`release-hq/parity/claude-code-prompts/09-weekly-recap.md`, "Trigger") requires the weekly
/// recap to fire only when the app is "calmly idle on Home" — never during an active/paused ride
/// or a GPS-lost/storage-low state.
///
/// Skipping is free: nothing is acknowledged when the gate says no, so the recap stays eligible
/// for the rest of its week and surfaces at the next calm moment. Expressed as plain booleans so
/// it stays a pure, dependency-free unit — the single `TrackingState.idle` mapping lives at the
/// call sites, exactly as on Android.
struct CalmMomentGate {

    /// A snapshot of everything that makes "now" a bad time to celebrate.
    ///
    /// - `isTrackingIdle`: tracking state is `.idle` — i.e. NOT `.tracking`, `.paused`, `.gpsLost`
    ///   or `.storageLow`. Anything other than idle means the user is mid-task.
    /// - `hasPendingReveal`: a B1 post-ride reveal is queued or on screen; the two celebrations
    ///   must never stack (pre-existing rule, folded in here so there is one gate, not two).
    struct AppMoment {
        var isTrackingIdle: Bool = true
        var hasPendingReveal: Bool = false

        init(isTrackingIdle: Bool = true, hasPendingReveal: Bool = false) {
            self.isTrackingIdle = isTrackingIdle
            self.hasPendingReveal = hasPendingReveal
        }
    }

    /// True only when every condition above is calm.
    static func isCalm(_ moment: AppMoment) -> Bool {
        moment.isTrackingIdle && !moment.hasPendingReveal
    }
}

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

    /// TASK-119: set when the calm gate — not the user — pulled a recap off screen. Prompt 30
    /// (`30-ios-weekly-recap-acknowledge-on-any-dismiss.md`) requires acknowledging on ANY user
    /// dismissal; a gate-driven park is not a dismissal and must not burn the week.
    private var parkedByGate = false

    private init() {}

    /// TASK-119: the live "is now a calm moment" snapshot, built from the app-scoped sources of
    /// truth. Mirrors Android `TrackMeApp.currentCalmMoment()`.
    func currentCalmMoment() -> CalmMomentGate.AppMoment {
        CalmMomentGate.AppMoment(
            isTrackingIdle: TrackingManager.shared.state == .idle,
            hasPendingReveal: RevealCoordinator.shared.pending != nil
        )
    }

    /// Ask the store for a pending recap (idempotent while one is already queued). Suppressed
    /// unless the app is calmly idle — no active/paused ride, no GPS-lost/storage-low
    /// state, no post-ride reveal — so the two celebrations never stack and neither lands
    /// mid-task (TASK-119).
    func check() async {
        guard pending == nil, CalmMomentGate.isCalm(currentCalmMoment()) else { return }
        pending = await RideStatsStore.shared.pendingWeeklyRecap()
        if let recap = pending {
            lastPresentedWeek = recap.weekStartEpochDay
            if lastTelemetryWeek != recap.weekStartEpochDay {
                lastTelemetryWeek = recap.weekStartEpochDay
                TelemetryManager.shared.trackWeeklyRecapShown(weekKey: recap.weekKey, rideCount: recap.rideCount, distanceKm: recap.distanceMeters / 1000.0)
            }
        }
    }

    /// TASK-119 render-time half of the gate (parity with Android's `HomeScreen` guard): pull a
    /// queued/presented recap off screen **without** acknowledging it when the moment stops being
    /// calm — e.g. a restored ride resumes tracking moments after launch. The week is left
    /// un-acked, so the next `check()` re-queues it.
    func parkIfNotCalm() {
        guard pending != nil, !CalmMomentGate.isCalm(currentCalmMoment()) else { return }
        parkedByGate = true
        pending = nil
    }

    /// True exactly once, when the last `pending -> nil` transition was a gate park rather than a
    /// user dismissal. The dismissal handler uses this to skip acknowledgement.
    func consumeGatePark() -> Bool {
        defer { parkedByGate = false }
        return parkedByGate
    }

    /// Acknowledge the recap after it has been presented (dedupe by week).
    func acknowledge(weekStartEpochDay: Int? = nil) async {
        guard let week = weekStartEpochDay ?? pending?.weekStartEpochDay ?? lastPresentedWeek else { return }
        pending = nil
        lastPresentedWeek = nil
        await RideStatsStore.shared.acknowledgeWeeklyRecap(weekStartEpochDay: week)
    }
}
