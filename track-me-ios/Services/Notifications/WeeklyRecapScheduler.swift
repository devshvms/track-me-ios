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
        case .returnAfterAbsence:
            return await scheduleReturnNotice(
                days: daysSinceLastActivity ?? 0, now: now, ledger: ledger, calendar: calendar
            )
        case .weeklyRecap:
            break
        case .none:
            return false
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
        // §6.1.7: the recap outlives its notification. Keyed by week, so the same recap read
        // in-app later does not produce a second row.
        BulletinStore.shared.add(BulletinAdapters.from(recap))
        return true
    }

    /// §6.1.3 scenario 13 — one notice, at 21 days or more, carrying a real fact.
    ///
    /// The closest this app comes to a line §4.2 N2 would otherwise forbid, and it survives only
    /// because of what it is not. Not loss-framed: no streak, no missed days, no falling number. It
    /// carries a fact someone might genuinely want — how long it has been, which people do lose
    /// track of — and it arrives at most once a quarter.
    ///
    /// Rationed twice: the shared weekly budget, and its own 90-day ledger. It is the only
    /// notification in the app that spends two allowances.
    private static func scheduleReturnNotice(
        days: Int,
        now: Date,
        ledger: ProactiveLedger,
        calendar: Calendar
    ) async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
                || settings.authorizationStatus == .ephemeral else { return false }

        let content = UNMutableNotificationContent()
        content.title = LocalizationHelper.localized("Your rides are still here")
        content.body = LocalizationHelper.formatted(
            "Your last recorded activity was %@ days ago. Everything you recorded is still on your phone.",
            String(days)
        )
        // .passive, like the recap. The most intrusive thing this app may say gets the quietest
        // delivery it can have while still being visible.
        content.interruptionLevel = .passive

        var components = calendar.dateComponents(
            [.year, .month, .day], from: nextDeliveryDate(after: now, calendar: calendar)
        )
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
            // Nothing recorded, so it stays eligible and the next foreground retries.
            CrashlyticsErrorLogger.shared.recordError(error)
            return false
        }

        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
        ledger.recordProactiveSent(at: nowMillis)
        ledger.recordReturnNoticeSent(at: nowMillis)
        return true
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
