import Foundation
import UserNotifications

/// SCOPE_1.8.7 §6.1.2 scenario 8 — the weekly recap, delivered to people who do not open the app.
///
/// ### Why iOS schedules and Android checks
///
/// Android runs a daily inexact `WorkManager` job that decides and posts. iOS has no equivalent it
/// can rely on — `BGAppRefreshTask` runs when the system feels like it, which for a once-a-week
/// notification means "possibly never on a lightly-used app".
///
/// So this schedules the **notification itself**, ahead of time, with a calendar trigger. Once
/// handed to `UNUserNotificationCenter` it fires whether or not the app ever runs again, which is
/// exactly the population §6.1.2 says the recap currently fails to reach. The content is fixed at
/// scheduling time, which is fine here and only here: a recap describes a *completed* week, so it
/// cannot change after the fact.
///
/// ### Why the week stays spent even if the notification is cancelled
///
/// If the rider opens the app and acknowledges the recap before it fires, the pending request is
/// cancelled — but the budget is **not** given back. They received the recap; it simply arrived by
/// the quieter route. Refunding the week would let an in-app acknowledgement re-open the budget for
/// another Class C source, which is a cap that loosens the more attentive the user is. Erring
/// toward fewer interruptions is the safe direction for a cap whose whole purpose is fewer
/// interruptions.
@MainActor
enum WeeklyRecapScheduler {

    static let identifier = "trackme.recap.weekly"

    /// The hour the recap arrives, local time.
    ///
    /// Late morning, not 8am: this is the least urgent thing the app says, and landing it in the
    /// same window as everybody's alarms and work notifications is how it gets swiped without being
    /// read. Nothing about a completed week is time-sensitive.
    static let deliveryHour = 10

    /// Decides which Class C source — if any — gets this week, and hands it to the system.
    ///
    /// §6.0: when several are eligible, exactly one is sent and the losers are **not** consumed;
    /// they stay eligible for their next window. `NotificationBudget.choose` decides by declared
    /// rank rather than by whichever check happens to run first, which is the only reason two
    /// sources can share one weekly allowance without one silently winning every time.
    ///
    /// - Returns: whether a notification was scheduled.
    @discardableResult
    static func scheduleIfDue(
        recap: WeeklyRecap?,
        daysSinceLastActivity: Int? = nil,
        now: Date = Date(),
        ledger: ProactiveLedger = ProactiveLedger(),
        calendar: Calendar = .current
    ) async -> Bool {
        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)

        // §6.1.7: the fact reaches the feed whether or not it earns an interruption. A recap the
        // budget refuses used to appear nowhere at all — which made "the bulletin is what lets the
        // cap be a trade rather than a loss" untrue for the one case it was written about. The
        // notification is a separate decision below; this is unconditional.
        if let ready = recap, ready.rideCount > 0 {
            BulletinStore.shared.add(BulletinAdapters.from(ready))
        }

        var eligible: Set<NotificationBudget.ProactiveKind> = []
        if WeeklyRecapNotice.shouldNotify(
            recap: recap,
            nowMillis: nowMillis,
            lastProactiveSentAtMillis: ledger.lastProactiveSentAtMillis,
            alreadyNotifiedWeekStart: ledger.lastRecapWeekStartEpochDay
        ) { eligible.insert(.weeklyRecap) }

        if let days = daysSinceLastActivity,
           NotificationBudget.allows(.proactive, nowMillis: nowMillis,
                                     lastProactiveSentAtMillis: ledger.lastProactiveSentAtMillis),
           NotificationBudget.allowsReturnNotice(
                nowMillis: nowMillis,
                lastReturnNoticeAtMillis: ledger.lastReturnNoticeAtMillis,
                daysSinceLastActivity: days
           ) { eligible.insert(.returnAfterAbsence) }

        switch NotificationBudget.choose(eligible) {
        case .returnAfterAbsence, .none:
            // The return notice is never *sent* here — it is armed for a future date and cancelled
            // if the rider comes back. See `armReturnNotice`. Arming happens on every foreground
            // regardless of which source won, because the switch has to be reset whenever the
            // last-activity date moves.
            return false
        case .weeklyRecap:
            break
        }

        guard let recap else { return false }

        // Follows the authorization already given, and never asks. TASK-284's rule is that a
        // permission prompt must arrive at a moment that earns it, and a weekly summary is the
        // weakest possible claim on someone's attention.
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
                || settings.authorizationStatus == .ephemeral else { return false }

        let content = UNMutableNotificationContent()
        content.title = LocalizationHelper.localized("Last week")
        content.body = LocalizationHelper.formatted(
            "%1$@ activities, %2$@.",
            String(recap.rideCount),
            UnitFormatter.distance(meters: recap.distanceMeters, unit: UnitSettings.shared.unit)
        )
        // .passive: it belongs in the list, not on the lock screen ahead of anything else. A sound
        // for a weekly summary is how a channel people were willing to keep gets turned off.
        content.interruptionLevel = .passive

        var components = calendar.dateComponents([.year, .month, .day], from: nextDeliveryDate(after: now, calendar: calendar))
        components.hour = deliveryHour
        components.minute = 0

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            // Nothing recorded, so the recap stays eligible and the next foreground retries.
            CrashlyticsErrorLogger.shared.recordError(error)
            return false
        }

        ledger.recordProactiveSent(at: nowMillis)
        ledger.recordRecapNotified(weekStartEpochDay: recap.weekStartEpochDay)
        return true
    }

    /// §6.1.3 scenario 13 — the return notice, scheduled *ahead* rather than after the fact.
    ///
    /// ### Why the first version was wrong
    ///
    /// It ran from `ContentView.onAppear` and scheduled the notice for 10:00 today or tomorrow —
    /// so the message "your last activity was 30 days ago" was queued at the exact moment the rider
    /// had come back, and arrived the next morning, possibly after they had already ridden again.
    /// A re-engagement notice sent *because* somebody re-engaged is worse than not sending one: it
    /// is the app demonstrating that it is not paying attention.
    ///
    /// ### What it does instead
    ///
    /// It behaves as a dead man's switch. On every foreground the pending notice is cancelled and,
    /// if the ledgers allow, re-armed for **21 days after the rider's last recorded activity**. Open
    /// the app and it is simply re-armed for the same date; record a ride and the date moves out;
    /// stop doing either and it eventually fires. That is the only shape in which "we have not
    /// heard from you" can be true at the moment it is delivered.
    ///
    /// ### Why the ledgers are not written here
    ///
    /// Cancellation is the *expected* path — most people come back. Recording a send at schedule
    /// time would spend a budget week and a 90-day quarter on a notification that is about to be
    /// cancelled, every time the app is opened. So the due date is stored instead, and the first
    /// launch after it has passed records the send. That is the only evidence iOS offers.
    static func armReturnNotice(
        daysSinceLastActivity: Int?,
        now: Date,
        ledger: ProactiveLedger,
        calendar: Calendar
    ) async -> Bool {
        // Always clear the old one first. Re-arming without cancelling would leave a notice
        // scheduled against a stale activity date.
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [returnIdentifier])

        guard let daysAway = daysSinceLastActivity else {
            // No recorded activity at all. Someone who has installed the app and not yet ridden has
            // not "been away", and welcoming them back from something they never left is the kind
            // of automated warmth that makes an app feel like it is not listening.
            ledger.clearPendingReturn()
            return false
        }

        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
        // The 90-day gate is checked against the moment it would *fire*, not now — the whole point
        // is that it fires in the future.
        let daysUntilEligible = NotificationBudget.returnNoticeMinAbsenceDays - daysAway
        guard let fireDate = calendar.date(
            byAdding: .day, value: max(daysUntilEligible, 0), to: now
        ) else { return false }

        let fireMillis = Int64(fireDate.timeIntervalSince1970 * 1000)
        guard NotificationBudget.allowsReturnNotice(
            nowMillis: fireMillis,
            lastReturnNoticeAtMillis: ledger.lastReturnNoticeAtMillis,
            daysSinceLastActivity: NotificationBudget.returnNoticeMinAbsenceDays
        ) else {
            ledger.clearPendingReturn()
            return false
        }

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
                || settings.authorizationStatus == .ephemeral else {
            ledger.clearPendingReturn()
            return false
        }

        // The body has to be written now for a notice that fires later, so it states the absence at
        // firing time — which is the threshold itself, not today's count.
        let content = UNMutableNotificationContent()
        content.title = LocalizationHelper.localized("Your rides are still here")
        // The body is written now for a notice that fires later, so it states the absence as it
        // will be *at firing time* — the threshold — rather than today's count, which will be wrong
        // by exactly the number of days we are waiting.
        let daysAtFiring = max(daysAway, NotificationBudget.returnNoticeMinAbsenceDays)
        content.body = LocalizationHelper.formatted(
            "Your last recorded activity was %@ days ago. Everything you recorded is still on your phone.",
            String(daysAtFiring)
        )
        // .passive, like the recap. The most intrusive thing this app may say gets the quietest
        // delivery it can have while still being visible.
        content.interruptionLevel = .passive

        var components = calendar.dateComponents([.year, .month, .day], from: fireDate)
        components.hour = deliveryHour
        components.minute = 0

        do {
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(
                    identifier: returnIdentifier,
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                )
            )
        } catch {
            CrashlyticsErrorLogger.shared.recordError(error)
            ledger.clearPendingReturn()
            return false
        }

        ledger.recordReturnScheduled(fireAtMillis: fireMillis)
        return true
    }

    /// Records a return notice that has already fired, on the first launch after its due date.
    ///
    /// The only moment iOS gives evidence that the notification was delivered rather than
    /// cancelled — so it is the only honest moment to spend the budget week and the quarter, and to
    /// add the bulletin row §6.1.7 requires for every notification actually sent.
    static func settleFiredReturnNotice(
        now: Date = Date(),
        ledger: ProactiveLedger = ProactiveLedger(),
        bulletin: BulletinStore = .shared
    ) {
        guard let due = ledger.pendingReturnFireAtMillis else { return }
        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
        guard nowMillis >= due else { return }

        ledger.clearPendingReturn()
        ledger.recordProactiveSent(at: due)
        ledger.recordReturnNoticeSent(at: due)
        bulletin.add(
            BulletinEntry(
                id: "return-notice:\(due)",
                kind: .returnNotice,
                createdAtMillis: due,
                facts: [BulletinEntry.factDaysAway: String(NotificationBudget.returnNoticeMinAbsenceDays)]
            )
        )
    }

    static let returnIdentifier = "trackme.recap.return"

    /// Cancels a pending recap notification — called when the rider has seen the recap in the app.
    ///
    /// The budget is deliberately not refunded; see the type documentation.
    static func cancelPending() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    /// The next delivery day: today if the hour has not passed, otherwise tomorrow.
    ///
    /// A trigger whose components are already in the past does not fire at all — it does not fire
    /// immediately either — so getting this wrong means the recap silently never arrives, which is
    /// indistinguishable from the bug this whole scenario exists to fix.
    static func nextDeliveryDate(after now: Date, calendar: Calendar = .current) -> Date {
        let hour = calendar.component(.hour, from: now)
        return hour < deliveryHour ? now : (calendar.date(byAdding: .day, value: 1, to: now) ?? now)
    }
}
