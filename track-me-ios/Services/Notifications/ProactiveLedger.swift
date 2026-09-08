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
    private let lastReturnActivityKey = "trackme_proactive_last_return_activity_at"
    private let lastRecapWeekKey = "trackme_proactive_last_recap_week"
    private let pendingReturnFireKey = "trackme_proactive_pending_return_fire_at"
    private let pendingReturnActivityKey = "trackme_proactive_pending_return_activity_at"

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

    /// The activity the last return notice described.
    var lastReturnNoticeActivityAtMillis: Int64? {
        (defaults.object(forKey: lastReturnActivityKey) as? NSNumber)?.int64Value
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

    func recordReturnNoticeSent(at sentAtMillis: Int64, activityAtMillis: Int64) {
        defaults.set(NSNumber(value: sentAtMillis), forKey: lastReturnKey)
        defaults.set(NSNumber(value: activityAtMillis), forKey: lastReturnActivityKey)
    }

    func recordRecapNotified(weekStartEpochDay: Int) {
        defaults.set(weekStartEpochDay, forKey: lastRecapWeekKey)
    }

    /// When a scheduled return notice is due to fire, or nil when none is pending.
    ///
    /// iOS cannot observe a notification firing, and for the return notice cancellation is the
    /// *expected* path — most people come back. So the ledgers cannot be written at schedule time
    /// the way the recap's are: doing that would spend a week and a quarter on a notification that
    /// is about to be cancelled, every single time somebody opens the app.
    ///
    /// Instead the due date is remembered here, and the next launch after it has passed is what
    /// records the send. That is the only moment iOS actually offers evidence.
    var pendingReturnFireAtMillis: Int64? {
        (defaults.object(forKey: pendingReturnFireKey) as? NSNumber)?.int64Value
    }

    var pendingReturnActivityAtMillis: Int64? {
        (defaults.object(forKey: pendingReturnActivityKey) as? NSNumber)?.int64Value
    }

    func recordReturnScheduled(fireAtMillis: Int64, activityAtMillis: Int64) {
        defaults.set(NSNumber(value: fireAtMillis), forKey: pendingReturnFireKey)
        defaults.set(NSNumber(value: activityAtMillis), forKey: pendingReturnActivityKey)
    }

    func clearPendingReturn() {
        defaults.removeObject(forKey: pendingReturnFireKey)
        defaults.removeObject(forKey: pendingReturnActivityKey)
    }
}
