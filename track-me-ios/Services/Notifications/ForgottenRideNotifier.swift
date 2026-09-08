import Foundation
import UserNotifications

/// SCOPE_1.8.7 §6.1.1 scenario 4 — asking whether a still, still-recording ride is over.
///
/// The policy is in ``ForgottenRideNotice``; this is the part that needs a device.
///
/// ### Two actions, and neither of them is "stop"
///
/// The notification offers **Finish ride** and **Keep recording**. Finishing routes through the same
/// path the user's own stop button uses — it does not have a private one that skips the save,
/// because a stop that loses the ride would turn a helpful question into the worst bug in the
/// release. Dismissing does nothing at all, which is the correct behaviour for a question whose
/// honest default is "carry on".
///
/// The Android twin is `ForgottenRideNotifier.kt`.
@MainActor
enum ForgottenRideNotifier {

    /// Stable identifier: a second ask replaces the first rather than stacking. In practice the
    /// once-per-ride flag means there is no second ask, but the identifier makes that structural.
    static let identifier = "trackme.ride.forgotten"
    static let categoryIdentifier = "trackme.ride.forgotten.category"
    static let finishActionIdentifier = "trackme.ride.forgotten.finish"
    static let keepActionIdentifier = "trackme.ride.forgotten.keep"

    /// Registered alongside the other categories at launch — a `categoryIdentifier` on content whose
    /// category was never registered silently shows no buttons at all.
    static var notificationCategory: UNNotificationCategory {
        let finish = UNNotificationAction(
            identifier: finishActionIdentifier,
            title: LocalizationHelper.localized("Finish ride"),
            options: [.foreground]
        )
        let keep = UNNotificationAction(
            identifier: keepActionIdentifier,
            title: LocalizationHelper.localized("Keep recording"),
            options: []
        )
        return UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [finish, keep],
            intentIdentifiers: [],
            options: []
        )
    }

    /// Posts the question and records it in the bulletin.
    ///
    /// - Parameters:
    ///   - elapsedSeconds: the whole ride so far, not the stillness. The rider's question is "how
    ///     long has this been running"; the stillness is the *reason* we are asking.
    ///   - stillSince: when movement stopped.
    static func notifyForgottenRide(elapsedSeconds: TimeInterval, stillSince: Date) async {
        let elapsedMinutes = Int(elapsedSeconds / 60)

        // The bulletin row goes in before the authorization check, and that ordering is the fix for
        // a real defect found in review: the in-app feed is precisely the surface that has to work
        // for someone who declined notifications, so gating it behind that authorization erases the
        // fallback §6.1.7 promises for exactly the population that depends on it.
        BulletinStore.shared.add(
            BulletinEntry(
                id: "forgotten-ride:\(Int(stillSince.timeIntervalSince1970))",
                kind: .forgottenRide,
                createdAtMillis: Int64(Date().timeIntervalSince1970 * 1000),
                facts: [
                    BulletinEntry.factElapsedMinutes: String(elapsedMinutes),
                    BulletinEntry.factStillSinceMillis: String(Int64(stillSince.timeIntervalSince1970 * 1000)),
                ]
            )
        )

        // Follows the authorization already given, and never asks — TASK-284's rule is that a
        // permission prompt must arrive at a moment that earns it, and mid-ride is not one.
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
                || settings.authorizationStatus == .ephemeral else { return }

        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none

        let content = UNMutableNotificationContent()
        content.title = LocalizationHelper.localized("Still recording")
        content.body = LocalizationHelper.formatted(
            "%1$@ min recorded. No movement since %2$@.",
            String(elapsedMinutes),
            formatter.string(from: stillSince)
        )
        content.categoryIdentifier = categoryIdentifier
        // .active, not .timeSensitive. A ride recording longer than it should is a data problem the
        // rider has hours to fix, and claiming time-sensitivity for it would spend a privilege that
        // belongs to things that cannot wait.
        content.interruptionLevel = .active

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            // nil trigger: deliver now. The decision to speak was already made by the policy.
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    static func cancel() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [identifier])
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
