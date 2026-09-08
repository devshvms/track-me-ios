import Foundation
import UserNotifications

/// SCOPE_1.8.7 §6.1.1 scenario 1 — telling someone their interrupted ride was saved.
///
/// Class A: about the user's data, so it is never rationed by the proactive budget. A ride
/// recovered in a week when a recap already went out is still a ride the user must be told about.
///
/// The launch toast already existed and is kept — but a toast requires the app to be open, and the
/// population that needs this most is the one whose phone died and has therefore stopped expecting
/// the ride to be there.
@MainActor
enum RecoveryNotifier {

    /// Stable identifier: a second recovery replaces the first rather than stacking two data
    /// notices about the same kind of thing.
    static let identifier = "trackme.recovery.saved"

    static func notify(summary: RecoverySummary) async {
        let single = summary.recovered.count == 1 ? summary.recovered.first : nil

        guard let notice = RecoveryNotice.decide(
            recoveredCount: summary.recoveredCount,
            discardedCount: summary.discardedCount,
            // Formatted here, in the layer that knows the locale and the unit preference; the
            // decision itself stays pure. Same split as ReplayOverlay, for the same reason.
            endedAtLabel: single.map {
                let formatter = DateFormatter()
                formatter.timeStyle = .short
                formatter.dateStyle = .none
                return formatter.string(from: $0.endTime)
            },
            distanceLabel: single.flatMap { ride -> String? in
                guard ride.distanceMeters >= 1 else { return nil }
                return UnitFormatter.distance(
                    meters: ride.distanceMeters,
                    unit: UnitSettings.shared.unit
                )
            }
        ) else { return }

        // Follows the authorization the user already gave, and never asks — TASK-284's rule is that
        // a permission prompt has to arrive at a moment that earns it, and this is not a prompt
        // moment. Someone who declined still sees the toast and the ride in History.
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
                || settings.authorizationStatus == .ephemeral else { return }

        let content = UNMutableNotificationContent()
        switch notice {
        case let .many(count):
            content.title = LocalizationHelper.formatted("%@ rides were saved", String(count))
            content.body = LocalizationHelper.localized(
                "The app closed while they were recording. They were finished and kept."
            )
        case let .one(endedAtLabel, distanceLabel):
            content.title = LocalizationHelper.localized("Your ride was saved")
            if let endedAtLabel, let distanceLabel {
                content.body = LocalizationHelper.formatted(
                    "Recording stopped at %1$@ because the app was closed. %2$@ was kept.",
                    endedAtLabel, distanceLabel
                )
            } else {
                content.body = LocalizationHelper.localized(
                    "The app closed while you were recording, so the ride was finished and kept."
                )
            }
        }
        // Not .timeSensitive. The news is good and the ride is not going anywhere — this should be
        // waiting when the phone is next picked up, not break through a Focus mode.
        content.interruptionLevel = .active
        content.sound = .default

        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        )
    }
}
