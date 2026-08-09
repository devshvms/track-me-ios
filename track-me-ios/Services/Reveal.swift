import Foundation

/// B1 post-ride reveal — a bounded, celebratory outcome shown once after a good ride is saved.
/// Parity with Android `Reveal`/`RevealSelector`. Pure value type (Codable) so it can be
/// persisted to survive backgrounding/process-death and shown exactly once.
///
/// "Bounded" is the guardrail: a small fixed set of *earned* outcomes, never slot-machine
/// randomness (trust for a safety app — user-psychology §1).
nonisolated struct Reveal: Codable, Identifiable, Equatable {
    let rideId: String
    let kind: RevealKind
    let totalRides: Int
    let distanceMeters: Double
    let durationMillis: Int64
    let milestoneRideCount: Int?

    var id: String { rideId }

    /// Telemetry value for `post_ride_reveal_shown {reveal_type}`. MUST stay within the A1
    /// taxonomy {"pr","first_ride","milestone","default"} and be identical to Android.
    var revealType: String {
        switch kind {
        case .firstRide: return "first_ride"
        case .distancePR, .durationPR: return "pr"
        case .milestone: return "milestone"
        case .standard: return "default"
        }
    }
}

/// The bounded reveal set. The two PR kinds collapse to the single `"pr"` telemetry type but
/// keep distinct copy (distance vs time). `standard` maps to `"default"`.
nonisolated enum RevealKind: String, Codable {
    case firstRide
    case distancePR
    case durationPR
    case milestone
    case standard
}

/// Pure B1 decision: `RideStatsTransition -> Reveal?`. The single place that decides which
/// bounded outcome a saved ride earns. Priority (highest first, parity with Android):
/// first ride → distance PR → duration PR → milestone → default. A single strict winner is
/// chosen so two outcomes never compete. Returns nil for an already-processed replay and for a
/// legacy retired-emergency ride; junk rides never reach here (excluded by the A1 hook upstream).
nonisolated enum RevealSelector {
    static func select(_ t: RideStatsTransition) -> Reveal? {
        // A legacy retired-emergency ride is still part of the user's history, but it must not
        // produce a celebratory reveal or chain into the App Store review prompt.
        guard !t.alreadyProcessed, !t.suppressPostRideCelebrations else { return nil }

        let kind: RevealKind
        if t.isFirstRide {
            kind = .firstRide
        } else if t.isDistancePR {
            kind = .distancePR
        } else if t.isDurationPR {
            kind = .durationPR
        } else if t.milestoneRideCount != nil {
            kind = .milestone
        } else {
            kind = .standard
        }

        return Reveal(
            rideId: t.rideId,
            kind: kind,
            totalRides: t.totalRides,
            distanceMeters: t.distanceMeters,
            durationMillis: t.durationMillis,
            milestoneRideCount: t.milestoneRideCount
        )
    }
}

/// Durable one-shot holder for the pending B1 reveal, observed by the Home surface.
///
/// Why persist (not a transient publish): the reveal is produced in a background `Task` after
/// `stopTracking()`, when the app may be backgrounding or about to be killed. It must survive
/// that and be shown once when Home is next foreground, then acknowledged. Mirrors Android's
/// `PendingRevealStore`. `@MainActor` so the `pending` binding is always mutated on the main
/// actor for SwiftUI.
@Observable
@MainActor
final class RevealCoordinator {
    static let shared = RevealCoordinator()

    private let defaults: UserDefaults
    private let key = "pending_reveal_v1"

    /// The reveal awaiting presentation, or nil. Seeded from disk so a reveal saved before
    /// process death is still delivered on next launch.
    var pending: Reveal?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let reveal = try? JSONDecoder().decode(Reveal.self, from: data) {
            self.pending = reveal
        }
    }

    /// Persist and surface a reveal (newest ride wins; reveals are not queued).
    func put(_ reveal: Reveal) {
        if let data = try? JSONEncoder().encode(reveal) {
            defaults.set(data, forKey: key)
        }
        pending = reveal
    }

    /// Acknowledge the reveal for `rideId`; no-op if a newer reveal has since replaced it.
    /// Precise API retained for callers/tests that know the rideId (e.g. the "Nice!" button).
    func consume(rideId: String) {
        guard pending?.rideId == rideId else { return }
        acknowledgeDisplayed()
    }

    /// Acknowledge whatever reveal is currently outstanding — the durable one-shot is spent once
    /// its sheet is dismissed by ANY means (button, swipe-down, interactive/system dismissal).
    /// Mirrors Android's `AlertDialog(onDismissRequest:)` → `PendingRevealStore.consume`. This is
    /// the path SwiftUI's `.sheet(item:)` swipe-dismiss must route through: the binding writes
    /// `pending = nil` in memory only and never calls `consume(rideId:)`, so without this the
    /// persisted `UserDefaults` key leaks and the reveal re-appears (and re-fires telemetry) on
    /// every cold launch. Idempotent by construction — safe to call after `pending` is already nil.
    func acknowledgeDisplayed() {
        defaults.removeObject(forKey: key)
        pending = nil
    }
}
