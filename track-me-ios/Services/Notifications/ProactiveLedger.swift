import Foundation

/// SCOPE_1.8.7 §6.0 — where the Class C budget's one piece of state lives.
///
/// The iOS twin of `data/local/ProactiveLedger.kt`.
///
/// `NotificationBudget` is pure and holds nothing; this is the ledger it reasons about.
/// Deliberately a single timestamp shared by **every** Class C source rather than one per feature:
/// the cap is one proactive notification per week *in total*, and a per-source ledger would quietly
/// become one per week per source, which is how a hard cap turns into a soft one without anybody
/// deciding to change it.
///
/// Writes happen only when a notification was genuinely delivered — or, on iOS, genuinely handed to
/// the system with a trigger that will fire. A refused or skipped C leaves this untouched; that is
/// what makes skipping free.
struct ProactiveLedger {

    private let defaults: UserDefaults
    private let lastSentKey = "trackme_proactive_last_sent_at"
    private let lastReturnKey = "trackme_proactive_last_return_at"
    private let lastRecapWeekKey = "trackme_proactive_last_recap_week"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// When a Class C notification was last actually sent, or nil if none ever has been.
    var lastProactiveSentAtMillis: Int64? {
        (defaults.object(forKey: lastSentKey) as? NSNumber)?.int64Value
    }

    /// The last time a return-after-absence notice was sent — scenario 13's second gate.
    var lastReturnNoticeAtMillis: Int64? {
        (defaults.object(forKey: lastReturnKey) as? NSNumber)?.int64Value
    }

    /// The last completed week whose recap was notified, so a week is never announced twice.
    var lastRecapWeekStartEpochDay: Int? {
        defaults.object(forKey: lastRecapWeekKey) as? Int
    }

    /// Records a delivered Class C notification.
    ///
    /// Routed through `NotificationBudget.recordSent` so the "never moves backwards" rule lives in
    /// the tested pure object rather than being restated here, where it would be one edit away from
    /// being lost.
    func recordProactiveSent(at sentAtMillis: Int64) {
        guard let updated = NotificationBudget.recordSent(
            .proactive,
            sentAtMillis: sentAtMillis,
            lastProactiveSentAtMillis: lastProactiveSentAtMillis
        ) else { return }
        defaults.set(NSNumber(value: updated), forKey: lastSentKey)
    }

    func recordReturnNoticeSent(at sentAtMillis: Int64) {
        defaults.set(NSNumber(value: sentAtMillis), forKey: lastReturnKey)
    }

    func recordRecapNotified(weekStartEpochDay: Int) {
        defaults.set(weekStartEpochDay, forKey: lastRecapWeekKey)
    }
}
