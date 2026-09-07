import Foundation

/// SCOPE_1.8.7 §6.1.2 scenarios 8 and 10a — the flagship Class C.
///
/// The iOS twin of `domain/notifications/WeeklyRecapNotice.kt`, rule for rule.
///
/// The recap already exists, is already deduped per week, and is already gated by `CalmMomentGate`.
/// What it is not, today, is reachable: it appears only if you open the app on a calm Monday, which
/// is exactly the population that needs it least.
///
/// ### Why 10a lives here rather than in its own notification
///
/// Scenario 10 — *"You're 20 minutes from Explorer"* as its own scheduled nudge — was **cut**. A
/// scheduled push toward a threshold is streak pressure wearing a different hat: the level is
/// measured in lifetime active minutes, so the only action it implies is "go exert yourself now,
/// because the app is counting", which §4.2 N2 rules out. 10a keeps the fact and drops the
/// interruption.
enum WeeklyRecapNotice {

    /// Roughly two good rides. Beyond that the fact is true and the sentence is not encouraging.
    static let maxMinutesWorthMentioning: Int64 = 120

    struct ProximityLine: Equatable {
        let minutes: Int64
        let levelName: String
    }

    /// Whether a recap should be *notified* — a stricter question than whether one exists.
    ///
    /// - Parameter alreadyNotifiedWeekStart: the last week whose recap was notified. The in-app
    ///   recap has its own acknowledgement; this is a separate marker on purpose, because seeing a
    ///   recap in the app and being interrupted about it are different events that must dedupe
    ///   separately.
    static func shouldNotify(
        recap: WeeklyRecap?,
        nowMillis: Int64,
        lastProactiveSentAtMillis: Int64?,
        alreadyNotifiedWeekStart: Int?
    ) -> Bool {
        guard let recap else { return false }
        // A zero-ride week is silent. The selector already guarantees this, and it is worth
        // restating: "you did nothing last week" is the exact message §4.2 N2 forbids, and it would
        // arrive automatically every week for anyone who had stopped riding.
        guard recap.rideCount > 0 else { return false }
        guard alreadyNotifiedWeekStart != recap.weekStartEpochDay else { return false }
        return NotificationBudget.allows(
            .proactive,
            nowMillis: nowMillis,
            lastProactiveSentAtMillis: lastProactiveSentAtMillis
        )
    }

    /// Scenario 10a: the level-proximity line, or nil when there is nothing true to say.
    static func proximityLine(minutesToNextLevel: Int64?, nextLevelName: String?) -> ProximityLine? {
        guard let minutes = minutesToNextLevel,
              let name = nextLevelName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        // Non-positive means the level was already reached — the reveal covered it, and saying
        // "0 minutes away" is the app failing to notice something the user already did.
        guard minutes > 0 else { return nil }
        // Far enough away that mentioning it is discouraging rather than motivating.
        guard minutes <= maxMinutesWorthMentioning else { return nil }
        return ProximityLine(minutes: minutes, levelName: name)
    }
}
