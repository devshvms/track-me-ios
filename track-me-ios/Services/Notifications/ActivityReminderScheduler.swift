import Foundation
import UserNotifications

/// SCOPE_1.8.7 §6.1.3 scenario 12a — storing the reminder the user set, and scheduling it.
///
/// ### iOS gets the easy half of this
///
/// The Android twin has to compute its own next-occurrence date and re-arm a one-shot worker,
/// because a daily `PeriodicWorkRequest` fires at an OS-chosen moment that can sit permanently
/// before the user's chosen hour. `UNCalendarNotificationTrigger` with `repeats: true` expresses
/// "every Saturday at 08:00" directly and the system owns the recurrence, so there is nothing to
/// re-arm and nothing to drift.
///
/// The two platforms therefore share the *policy* (``ActivityReminder``) and not the scheduling,
/// which is the right split: the decision about whether a reminder should exist is a product rule
/// and identical, while how it recurs is a platform capability and is not.
///
/// ### Nothing here enables anything
///
/// ``save(_:)`` is the only writer, and it is called from the settings screen. There is no
/// migration, no enable-on-upgrade, and no default that is on. §6.1.3's distinction between the
/// shipped 12a and the cut scenario 12 is that a human turned this on.
@MainActor
enum ActivityReminderScheduler {

    static let identifier = "trackme.reminder.activity"

    private static let enabledKey = "trackme.reminder.enabled"
    private static let dayKey = "trackme.reminder.day"
    private static let daysKey = "trackme.reminder.days"
    private static var scheduleRevision = 0
    private static let hourKey = "trackme.reminder.hour"
    private static let minuteKey = "trackme.reminder.minute"
    private static let personaKey = "trackme.reminder.persona"

    static var settings: ActivityReminder.Settings {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: enabledKey) != nil else { return ActivityReminder.Settings() }
        return ActivityReminder.Settings(
            enabled: defaults.bool(forKey: enabledKey),
            dayOfWeek: defaults.object(forKey: dayKey) as? Int ?? ActivityReminder.Settings.defaultDay,
            hour: defaults.object(forKey: hourKey) as? Int ?? ActivityReminder.Settings.defaultHour,
            minute: defaults.object(forKey: minuteKey) as? Int ?? 0,
            persona: defaults.string(forKey: personaKey) ?? ActivityReminder.Settings.defaultPersona,
            daysOfWeek: (defaults.array(forKey: daysKey) as? [Int]).map { Set($0) }
        )
    }

    /// Persists the settings and brings the scheduled notification into line with them.
    static func save(_ settings: ActivityReminder.Settings) async {
        let defaults = UserDefaults.standard
        defaults.set(settings.enabled, forKey: enabledKey)
        defaults.set(settings.dayOfWeek, forKey: dayKey)
        defaults.set(settings.selectedDays.sorted(), forKey: daysKey)
        defaults.set(settings.hour, forKey: hourKey)
        defaults.set(settings.minute, forKey: minuteKey)
        defaults.set(settings.persona, forKey: personaKey)
        await reschedule(settings)
    }

    /// Re-registers the repeating trigger, or removes it when the reminder is off or invalid.
    static func reschedule(_ override: ActivityReminder.Settings? = nil) async {
        // Resolved inside the body rather than as a default argument: a default expression is
        // evaluated in the caller's isolation, and this one reads main-actor state.
        let settings = override ?? ActivityReminderScheduler.settings
        scheduleRevision += 1
        let revision = scheduleRevision
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [identifier] + (1...7).map { "\(identifier).\($0)" })

        guard settings.enabled, settings.isValid else { return }

        // Follows the authorization already given, and never asks. Someone who declined still has a
        // reminder stored and will get it if they later allow notifications — removing the stored
        // setting because the OS permission is off would silently discard a choice they made.
        let authorization = await UNUserNotificationCenter.current().notificationSettings()
        guard revision == scheduleRevision else { return }
        guard authorization.authorizationStatus == .authorized
                || authorization.authorizationStatus == .provisional
                || authorization.authorizationStatus == .ephemeral else { return }

        let content = UNMutableNotificationContent()
        // `displayName` is the raw English enum name, so it goes through the localizer the same way
        // every other persona-naming surface does — a notification reading "Your Cycling reminder"
        // in a German app is the one place the user cannot miss it.
        let persona = RidePersona.fromStoredName(settings.persona)
        content.title = LocalizationHelper.formatted(
            "Your %@ reminder", LocalizationHelper.localized(persona.displayName)
        )
        content.body = LocalizationHelper.localized("You asked to be reminded at this time.")
        // .active, unlike every Class C notice in this release, and the difference is the point:
        // the user picked this moment, so arriving quietly enough to be missed would fail the only
        // thing they asked for.
        content.interruptionLevel = .active

        for day in settings.selectedDays.sorted() {
        guard revision == scheduleRevision else { return }
        var components = DateComponents()
        components.weekday = RideHistoryProfileSource.foundationWeekday(day)
        components.hour = settings.hour
        components.minute = settings.minute

        let request = UNNotificationRequest(
            identifier: "\(identifier).\(day)",
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        )
        try? await UNUserNotificationCenter.current().add(request)
        // A newer edit may have cancelled while add was suspended. Repair to current settings.
        if revision != scheduleRevision {
            await reschedule()
            return
        }
        }
    }
}
