import Foundation
import FirebaseMessaging
import UserNotifications

/// SCOPE_1.8.7 §6.3 — subscribing this install to operator broadcasts.
///
/// ### Why a topic, and why that is the privacy story
///
/// The obvious design is a `push_tokens` collection: every install registers its FCM token, the
/// server keeps a row per device, and a send fans out over them. That means holding a **device
/// identifier for every user**, declaring it in App Privacy and Data Safety on both stores,
/// deleting it on sign-out and again on account deletion, and never letting those two paths drift.
///
/// A topic needs none of it. The client subscribes itself; the server addresses `broadcasts` and
/// never learns who is listening. Nothing to declare, nothing to retain, nothing to delete — and
/// per-user targeting becomes *impossible* rather than merely forbidden, which is a better way to
/// keep a promise than remembering to.
///
/// The honest cost: no delivery receipts and no per-user retry. For "the build you are running has
/// a defect", that is the right trade, and the foreground read of the `broadcasts` collection
/// covers anyone the push missed.
///
/// ### Authorization is the subscription, and this never asks for it
///
/// `sync()` follows the notification authorization the user has already given. It does **not**
/// request it: TASK-284's rule is that a permission prompt has to arrive at a moment that earns it,
/// and a broadcast arriving is not that moment. Someone who declined stays unsubscribed and still
/// sees the message in the app.
enum BroadcastSubscription {

    /// Must match `BROADCAST_TOPIC` in `api/admin/broadcast.ts` and Android's
    /// `BroadcastSubscription.TOPIC`.
    static let topic = "broadcasts"

    /// Aligns the topic subscription with the notification authorization already granted.
    ///
    /// Both calls are idempotent on FCM's side, so running this on every launch is cheap and is the
    /// only thing that recovers a subscription after a reinstall, a restore, or the user turning
    /// notifications back on in Settings without opening anything of ours.
    static func sync() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let authorized = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
                || settings.authorizationStatus == .ephemeral
            Task {
                do {
                    if authorized {
                        try await Messaging.messaging().subscribe(toTopic: topic)
                    } else {
                        try await Messaging.messaging().unsubscribe(fromTopic: topic)
                    }
                } catch {
                    // Not fatal and not worth telling the user: the next launch retries, and the
                    // foreground read of `broadcasts` means nothing is actually missed meanwhile.
                    CrashlyticsErrorLogger.shared.recordError(error)
                }
            }
        }
    }
}
