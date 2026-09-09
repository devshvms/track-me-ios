import Foundation

/// SCOPE_1.8.7 §6.1.3 scenario 12a — a reminder the user set, at a time the user chose.
///
/// ### This is Class B, and that is the whole design
///
/// §6.0's interruption budget caps Class C at one per seven days across every source. This does not
/// touch that budget, and the reason is not generosity: a Class B notification is one the user asked
/// for, on a cadence they picked, and spending their weekly proactive allowance on their own alarm
/// clock would mean the app punishing them for using a feature. The budget exists to limit what the
/// *app* decides to say. This is not the app deciding.
///
/// The corollary is the part that has to hold: if this can ever fire without the user having set
/// it, the exemption becomes a loophole. So ``Settings/enabled`` defaults to false, there is no code
/// path that enables it except a user action, and the suggestion in ``RideHistoryProfile`` is
/// offered as pre-filled form values rather than as a reminder that already exists.
///
/// ### Weekly, not daily
///
/// A daily reminder for an activity almost nobody does daily is a notification that is wrong six
/// times a week, and being wrong on a channel the user opted into is how an opt-in channel becomes
/// one they turn off. One weekday, one time.
///
/// The Android twin is `ActivityReminder.kt`.
enum ActivityReminder {

    /// A reminder as the user has it configured.
    ///
    /// - Parameters:
    ///   - dayOfWeek: ISO-8601: 1 = Monday … 7 = Sunday, matching ``RideHistoryProfile/Sample``.
    ///   - persona: what the reminder is for. Carried so the copy can name the activity rather than
    ///     say "time to exercise", which is the tone §4.2 N2 rules out.
    struct Settings: Equatable {
        var enabled: Bool
        var dayOfWeek: Int
        var hour: Int
        var minute: Int
        var persona: String
        var daysOfWeek: Set<Int>?
        var selectedDays: Set<Int> { daysOfWeek ?? [dayOfWeek] }

        /// Saturday morning. Only ever seen by someone who opened the screen with no history to
        /// suggest from and did not touch the pickers — the least presumptuous slot available, not
        /// a recommendation.
        static let defaultDay = 6
        static let defaultHour = 8
        static let defaultPersona = "AUTO"

        init(
            enabled: Bool = false,
            dayOfWeek: Int = Settings.defaultDay,
            hour: Int = Settings.defaultHour,
            minute: Int = 0,
            persona: String = Settings.defaultPersona,
            daysOfWeek: Set<Int>? = nil
        ) {
            self.enabled = enabled
            self.dayOfWeek = dayOfWeek
            self.hour = hour
            self.minute = minute
            self.persona = persona
            self.daysOfWeek = daysOfWeek
        }

        /// Whether these settings describe something schedulable.
        var isValid: Bool {
            !selectedDays.isEmpty && selectedDays.allSatisfy { (1...7).contains($0) }
                && (0...23).contains(hour) && (0...59).contains(minute)
        }
    }

    /// The settings to pre-fill the form with, given whatever history exists.
    ///
    /// Returns settings with `enabled == false` in every case. Nothing here schedules anything;
    /// that requires the user pressing the toggle, which is the entire distinction between 12a and
    /// the cut scenario 12.
    static func prefill(_ suggestion: RideHistoryProfile.SuggestedSlot?) -> Settings {
        guard let suggestion else { return Settings() }
        return Settings(
            enabled: false,
            dayOfWeek: suggestion.dayOfWeek,
            hour: suggestion.hour,
            minute: 0,
            persona: suggestion.persona
        )
    }

    /// Whether a reminder is due to fire, evaluated against the slot the user picked.
    ///
    /// - Parameter lastFiredEpochDay: a stable per-day marker for the last firing, or nil. Both
    ///   platforms' schedulers can wake more than once inside the firing window, and a reminder that
    ///   arrives twice on the same morning reads as a bug in a way a missed one does not.
    static func shouldFire(
        settings: Settings,
        nowDayOfWeek: Int,
        nowEpochDay: Int64,
        lastFiredEpochDay: Int64?
    ) -> Bool {
        guard settings.enabled, settings.isValid else { return false }
        guard settings.selectedDays.contains(nowDayOfWeek) else { return false }
        if let lastFiredEpochDay, lastFiredEpochDay >= nowEpochDay { return false }
        return true
    }
}
