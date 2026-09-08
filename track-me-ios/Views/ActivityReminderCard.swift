import SwiftUI
import SwiftData

/// SCOPE_1.8.7 §6.1.3 scenario 12a — the screen where the inference becomes a courtesy.
///
/// ### The suggestion is an offer, and the UI has to look like one
///
/// Scenario 12 was cut for inferring a routine and acting on it. What makes 12a shippable is not
/// that the inference is weaker — it is the same inference — but that it arrives as *"Suggested from
/// your history: Saturday, 8:00"* next to a button the user has to press. The copy naming its own
/// source is load-bearing: an app that silently pre-fills the right answer is still an app that has
/// been watching, and hiding that is worse than saying it.
///
/// So: the toggle is off, the suggestion is visibly a suggestion, and ``RideHistoryProfile`` returns
/// nothing at all when the history is thin — in which case this shows a plain form and says why.
///
/// The Android twin is `ActivityReminderSection.kt`.
struct ActivityReminderCard: View {

    @Environment(\.modelContext) private var modelContext

    @State private var settings = ActivityReminder.Settings()
    @State private var suggestion: RideHistoryProfile.SuggestedSlot?
    @State private var historyLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(LocalizationHelper.localized("Activity reminder"))
                .font(.headline)
                .foregroundColor(.primary)

            Text(LocalizationHelper.localized(
                "One reminder a week, at a time you choose. Off unless you turn it on."
            ))
            .font(.caption)
            .foregroundColor(.gray)

            HStack(alignment: .top) {
                Text(LocalizationHelper.localized("Remind me weekly"))
                    .font(.subheadline)
                    .foregroundColor(.primary)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { settings.enabled },
                    set: { enabled in
                        settings.enabled = enabled
                        persist()
                    }
                ))
                .labelsHidden()
                .tint(BrandColor.primary)
                .accessibilityLabel(LocalizationHelper.localized("Remind me weekly"))
            }

            // The suggestion sits above the pickers and outside the enabled gate: it is the reason
            // someone would turn this on, so hiding it until they already have is backwards.
            if historyLoaded {
                if let slot = suggestion {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(LocalizationHelper.formatted(
                            "Suggested from your history: %1$@, %2$@",
                            weekdayName(slot.dayOfWeek),
                            timeLabel(hour: slot.hour, minute: 0)
                        ))
                        .font(.caption)
                        .foregroundColor(.gray)

                        Button(LocalizationHelper.localized("Use this")) {
                            // Applies the slot; it does **not** enable the reminder. Filling a form
                            // is not consent to the thing the form describes.
                            let enabled = settings.enabled
                            settings = ActivityReminder.prefill(slot)
                            settings.enabled = enabled
                            persist()
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                    }
                } else {
                    Text(LocalizationHelper.localized(
                        "Record a few activities and we can suggest a time."
                    ))
                    .font(.caption)
                    .foregroundColor(.gray)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(LocalizationHelper.localized("Day"))
                    .font(.subheadline)
                    .foregroundColor(.primary)
                Picker("", selection: Binding(
                    get: { settings.dayOfWeek },
                    set: { settings.dayOfWeek = $0; persist() }
                )) {
                    ForEach(1...7, id: \.self) { iso in
                        Text(weekdayShortName(iso)).tag(iso)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(LocalizationHelper.localized("Day"))
            }

            DatePicker(
                LocalizationHelper.localized("Time of day"),
                selection: Binding(
                    get: { dateFor(hour: settings.hour, minute: settings.minute) },
                    set: { newValue in
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                        settings.hour = parts.hour ?? settings.hour
                        settings.minute = parts.minute ?? settings.minute
                        persist()
                    }
                ),
                displayedComponents: .hourAndMinute
            )
            .font(.subheadline)

            VStack(alignment: .leading, spacing: 8) {
                Text(LocalizationHelper.localized("Activity"))
                    .font(.subheadline)
                    .foregroundColor(.primary)
                Picker("", selection: Binding(
                    get: { settings.persona },
                    set: { settings.persona = $0; persist() }
                )) {
                    ForEach(RidePersona.allCases, id: \.rawValue) { persona in
                        // `displayName` is the raw English enum name; every persona-naming surface
                        // sends it through the localizer.
                        Text(LocalizationHelper.localized(persona.displayName)).tag(persona.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel(LocalizationHelper.localized("Activity"))
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
        .task {
            settings = ActivityReminderScheduler.settings
            suggestion = RideHistoryProfile.suggestSlot(
                RideHistoryProfileSource.samples(context: modelContext)
            )
            historyLoaded = true
        }
    }

    private func persist() {
        let snapshot = settings
        Task { await ActivityReminderScheduler.save(snapshot) }
    }

    private func dateFor(hour: Int, minute: Int) -> Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components) ?? Date()
    }

    /// Honours the device's 12/24-hour setting rather than hard-coding either.
    private func timeLabel(hour: Int, minute: Int) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: dateFor(hour: hour, minute: minute))
    }

    private func weekdayName(_ isoDayOfWeek: Int) -> String {
        let symbols = DateFormatter().standaloneWeekdaySymbols ?? Calendar.current.weekdaySymbols
        return symbols[RideHistoryProfileSource.foundationWeekday(isoDayOfWeek) - 1]
    }

    private func weekdayShortName(_ isoDayOfWeek: Int) -> String {
        let symbols = DateFormatter().shortStandaloneWeekdaySymbols
            ?? Calendar.current.shortWeekdaySymbols
        return symbols[RideHistoryProfileSource.foundationWeekday(isoDayOfWeek) - 1]
    }
}
