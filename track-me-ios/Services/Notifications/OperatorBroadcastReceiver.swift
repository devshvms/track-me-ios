import Foundation
import UIKit
import UserNotifications

/// SCOPE_1.8.7 §6.3 — turns a received data-only push into a validated, stored, posted broadcast.
///
/// The iOS twin of `TrackMeMessagingService`, and the only place in the app where content from the
/// network becomes a notification — which is why almost all of it is validation.
///
/// ### Why the payload is data-only
///
/// The endpoint deliberately sends no `alert`. An alert payload is rendered by the system **before
/// this code runs**, so an unvalidated string from the network would reach the user with no parser
/// in the way, and the closed tag vocabulary, the length limits and the https check would all be
/// decoration. Data-only means we validate first and post a local notification second, every time.
///
/// ### Dropping is safe; rendering something wrong is not
///
/// Anything `OperatorBroadcast.parse` refuses is discarded silently. The same broadcast is also in
/// the `broadcasts` collection and read on next foreground, so a dropped push costs a delay, while
/// a rendered malformed one costs the channel the credibility that makes it worth having.
@MainActor
enum OperatorBroadcastReceiver {

    /// Notification-centre grouping id, so several broadcasts stack together rather than
    /// interleaving with ride and group notifications.
    static let threadIdentifier = "trackme.operator.broadcast"

    /// - Returns: whether anything new was stored, so the caller can report the right
    ///   `UIBackgroundFetchResult` — claiming `.newData` for a duplicate teaches iOS to throttle
    ///   deliveries the user does need.
    @discardableResult
    static func handle(_ userInfo: [AnyHashable: Any], store: BroadcastStore = .shared) -> Bool {
        guard let broadcast = OperatorBroadcast.parse(userInfo) else { return false }

        // Not true for this build. An update notice telling someone already on the fixed version to
        // update is the noise that teaches people to swipe away the one message that mattered.
        guard broadcast.applies(toVersionCode: currentVersionCode()) else { return false }

        // The same broadcast genuinely arrives twice — once by push, once by the foreground read.
        // Only the first arrival may interrupt.
        guard store.store(broadcast) else { return false }

        post(broadcast)
        return true
    }

    private static func post(_ broadcast: OperatorBroadcast) {
        let content = UNMutableNotificationContent()
        content.title = broadcast.title
        content.body = broadcast.body
        content.threadIdentifier = threadIdentifier
        content.interruptionLevel = .timeSensitive
        content.sound = .default

        // Identifier from the broadcast id, so a duplicate delivery replaces rather than stacks and
        // two different broadcasts never collapse into one.
        let request = UNNotificationRequest(
            identifier: "\(threadIdentifier).\(broadcast.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error { CrashlyticsErrorLogger.shared.recordError(error) }
        }
    }

    /// The running build number.
    ///
    /// `Int.max` when it cannot be read: a device whose own version we cannot determine must not be
    /// told to update to fix a bug it may not have. Silence is the safe direction for a message
    /// about correctness.
    static func currentVersionCode() -> Int {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let value = Int(raw) else { return Int.max }
        return value
    }
}
