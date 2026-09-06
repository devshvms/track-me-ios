import Foundation

/// SCOPE_1.8.7 §6.0 — the interruption budget.
///
/// The object that makes *"not too many notifications"* testable rather than a matter of taste,
/// which matters because taste loses arguments to growth ideas and a hard cap does not.
///
/// Every notification belongs to exactly one class:
///
/// - **`.consequential`** (A) — something happened to the user's data or ride that they must know
///   about. Unlimited, but each is rare by construction: a ride is only auto-finalized once.
/// - **`.requested`** (B) — the user asked for this one, at a time they chose. Rationing a reminder
///   someone set themselves would be the app overruling a schedule they can see and edit.
/// - **`.proactive`** (C) — the app decided to speak. **One per seven days, across every C source
///   combined.** Where every re-engagement idea lands, and where every app in this category loses
///   its users' trust.
/// - **`.operator`** (D) — a person at TrackMe needs to say something operational (§6.3). Outside
///   the C budget in **both** directions, deliberately.
///
/// ### Skipping is free
///
/// `allows` is a pure query and `recordSent` is the only thing that moves the ledger. That
/// separation is the entire "a skipped C is not consumed" property: a recap the budget refuses
/// stays eligible for the rest of its week and lands at the next calm moment. A cap that *lost*
/// notifications rather than deferring them would make one-per-week a real restriction instead of
/// merely an honest one.
///
/// ### Why D sits outside the budget in both directions
///
/// A maintenance notice suppressed because a weekly recap went out on Tuesday is an outage nobody
/// was told about. And a broadcast that advanced the ledger would let the operator channel mute the
/// product's own voice for a week — worse, it would make "send a broadcast" a lever on engagement,
/// which is exactly what §6.3's promotional ban exists to prevent.
///
/// Byte-for-byte with Android's `domain/notifications/NotificationBudget.kt`, proved by the same
/// frozen vectors (`notification-budget-v1.json`).
enum NotificationBudget {

    /// One Class C notification per seven days, across all C sources combined.
    static let proactiveIntervalMillis: Int64 = 7 * 24 * 60 * 60 * 1000

    /// Scenario 13's own cap, on top of the C budget. See `allowsReturnNotice`.
    static let returnNoticeIntervalMillis: Int64 = 90 * 24 * 60 * 60 * 1000

    /// The notification threshold for "you have been away", in days.
    ///
    /// Deliberately higher than `HomeInsight.Return`'s in-app threshold of 14: interrupting someone
    /// is a bigger claim than showing them something once they have already opened the app.
    static let returnNoticeMinAbsenceDays: Int = 21

    enum Klass: String, CaseIterable {
        case consequential = "CONSEQUENTIAL"
        case requested = "REQUESTED"
        case proactive = "PROACTIVE"
        case operatorBroadcast = "OPERATOR"

        /// Only Class C is rationed, and only Class C moves the ledger.
        var spendsProactiveBudget: Bool { self == .proactive }
    }

    /// The Class C sources, **in priority order**. The declaration order is the contract, so
    /// reordering this changes behaviour and should be a deliberate act.
    enum ProactiveKind: String, CaseIterable {
        /// Scenario 13. Ranked first because it is far rarer — once per 90 days at most — and
        /// because the recap it would otherwise lose to is, for someone who has been away, a report
        /// of a week in which they did nothing.
        case returnAfterAbsence = "RETURN_AFTER_ABSENCE"

        /// Scenario 8, the flagship C. Carries scenario 10a's level-proximity line, so the level
        /// fact reaches the user without an interruption of its own.
        case weeklyRecap = "WEEKLY_RECAP"
    }

    /// May a notification of `klass` be sent right now?
    ///
    /// - Parameter lastProactiveSentAtMillis: when a Class C was last actually sent, or nil if none
    ///   ever has been. A fresh install is not owed a week of silence first.
    static func allows(_ klass: Klass, nowMillis: Int64, lastProactiveSentAtMillis: Int64?) -> Bool {
        guard klass.spendsProactiveBudget else { return true }
        guard let last = lastProactiveSentAtMillis else { return true }
        // A last-sent time in the future is not a reason to send. Clock changes, restores from
        // backup and timezone edits all produce it, and treating it as "long ago" would make a
        // device whose clock jumped backwards emit a proactive notification on every launch until
        // real time caught up.
        if nowMillis < last { return false }
        return nowMillis - last >= proactiveIntervalMillis
    }

    /// The ledger after sending `klass` at `sentAtMillis`. Call only when a notification was
    /// genuinely delivered — a skipped or suppressed C must leave the ledger untouched.
    ///
    /// Never moves backwards: an out-of-order send on a device whose clock went back must not
    /// reopen the week.
    static func recordSent(_ klass: Klass, sentAtMillis: Int64, lastProactiveSentAtMillis: Int64?) -> Int64? {
        guard klass.spendsProactiveBudget else { return lastProactiveSentAtMillis }
        guard let last = lastProactiveSentAtMillis else { return sentAtMillis }
        return max(last, sentAtMillis)
    }

    /// The single Class C to send when several are eligible, or nil when none are.
    ///
    /// The losers are **not** consumed — nothing here records anything. They stay eligible for
    /// their next window, exactly as `WeeklyRecapSelector` already behaves.
    ///
    /// Returns by declared rank rather than by iteration order, because a `Set` on one platform and
    /// an `Array` on the other is precisely how a silent priority divergence arrives.
    static func choose(_ eligible: Set<ProactiveKind>) -> ProactiveKind? {
        ProactiveKind.allCases.first { eligible.contains($0) }
    }

    /// Scenario 13's second gate, applied on top of `allows`.
    ///
    /// Rationed twice because a return notice is the most intrusive thing this app may say: it is a
    /// message about *not* having done something, which §4.2 N2 otherwise rules out entirely. It
    /// survives at all only because it is gain-framed, carries a real fact, and arrives at most
    /// once a quarter.
    static func allowsReturnNotice(
        nowMillis: Int64,
        lastReturnNoticeAtMillis: Int64?,
        daysSinceLastActivity: Int
    ) -> Bool {
        // They came back. The 90-day window may well be open, but there is nothing to say — and
        // saying it anyway is exactly how a return notice becomes a streak reminder.
        if daysSinceLastActivity < returnNoticeMinAbsenceDays { return false }
        guard let last = lastReturnNoticeAtMillis else { return true }
        if nowMillis < last { return false }
        return nowMillis - last >= returnNoticeIntervalMillis
    }
}
