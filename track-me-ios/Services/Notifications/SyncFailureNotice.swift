import Foundation
import UserNotifications

/// SCOPE_1.8.7 §6.1.5 scenario 23 — telling someone their cloud backup has stopped working.
///
/// The iOS twin of `domain/notifications/SyncFailureNotice.kt`, rule for rule.
///
/// §6.1.5 is blunt about why this matters: *"A user who enabled sync believes their data is safe.
/// Silent persistent failure is the worst class of bug in a data-ownership product."* Someone who
/// turned sync on has stopped worrying about their rides. If it quietly stops, they keep not
/// worrying, right up until the phone is lost.
enum SyncFailureNotice {

    /// How many consecutive failures before saying anything.
    ///
    /// Three, not one. Sync fails constantly and harmlessly — a tunnel, a café network, airplane
    /// mode — and an app that notified on every failure would be crying wolf within a day, so the
    /// notification that mattered would arrive to someone who had already turned the channel off.
    static let consecutiveFailuresBeforeNotice = 3

    struct Episode: Equatable {
        var consecutiveFailures: Int = 0
        var notified: Bool = false
    }

    /// Whether to tell the user their backup is failing.
    ///
    /// - Parameter unsyncedRideCount: rides that have not reached the cloud. The number in the
    ///   message, and the reason there is a message at all.
    static func shouldNotify(
        consecutiveFailures: Int,
        unsyncedRideCount: Int,
        alreadyNotifiedThisEpisode: Bool
    ) -> Bool {
        if alreadyNotifiedThisEpisode { return false }
        if consecutiveFailures < consecutiveFailuresBeforeNotice { return false }
        // Nothing waiting means nothing at risk. A failing sync with an empty queue is the app
        // reporting its own internal state, which is not a fact about the user (§4.2 N1).
        if unsyncedRideCount <= 0 { return false }
        return true
    }

    /// The episode state after an attempt.
    ///
    /// A success clears everything — including the notified flag, which is what makes "once per
    /// episode" mean an episode rather than "once, ever". A user whose backup breaks twice in a
    /// year should be told twice.
    static func record(succeeded: Bool, state: Episode) -> Episode {
        succeeded ? Episode() : Episode(
            consecutiveFailures: state.consecutiveFailures + 1,
            notified: state.notified
        )
    }
}

/// SCOPE_1.8.7 §6.1.5 scenario 23 — the episode state and the notice itself.
///
/// Class A. Never rationed by the proactive budget: a backup that broke during a week when a recap
/// went out is still a broken backup.
@MainActor
struct SyncFailureNotifier {

    static let identifier = "trackme.sync.failing"

    private let defaults: UserDefaults
    private let failuresKey = "trackme_sync_consecutive_failures"
    private let notifiedKey = "trackme_sync_notified_this_episode"
    private let lastSuccessKey = "trackme_sync_last_success_at"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Records the outcome of a sync attempt and notifies if this is the moment to.
    func recordAttempt(
        succeeded: Bool,
        unsyncedRideCount: Int,
        now: Date = Date(),
        bulletin: BulletinStore = .shared
    ) async {
        let before = SyncFailureNotice.Episode(
            consecutiveFailures: defaults.integer(forKey: failuresKey),
            notified: defaults.bool(forKey: notifiedKey)
        )
        let after = SyncFailureNotice.record(succeeded: succeeded, state: before)

        guard !succeeded else {
            // A success is what ends an episode — and what makes "once per episode" mean an episode
            // rather than "once, ever".
            defaults.set(0, forKey: failuresKey)
            defaults.set(false, forKey: notifiedKey)
            defaults.set(now, forKey: lastSuccessKey)
            return
        }

        defaults.set(after.consecutiveFailures, forKey: failuresKey)

        guard SyncFailureNotice.shouldNotify(
            consecutiveFailures: after.consecutiveFailures,
            unsyncedRideCount: unsyncedRideCount,
            alreadyNotifiedThisEpisode: after.notified
        ) else { return }

        let lastSuccess = defaults.object(forKey: lastSuccessKey) as? Date

        // The bulletin gets the row whether or not a notification can be posted: someone who
        // declined notifications still needs to be able to find out their backup is broken.
        var facts = [BulletinEntry.factUnsyncedCount: String(unsyncedRideCount)]
        if let lastSuccess {
            facts[BulletinEntry.factSinceMillis] = String(Int64(lastSuccess.timeIntervalSince1970 * 1000))
        }
        bulletin.add(
            BulletinEntry(
                // One row per episode, keyed by when it started failing rather than by "now", so a
                // retry that notifies again cannot stack rows about one outage.
                id: "sync-problem:\(Int64((lastSuccess ?? .distantPast).timeIntervalSince1970))",
                kind: .syncProblem,
                createdAtMillis: Int64(now.timeIntervalSince1970 * 1000),
                facts: facts
            )
        )

        defaults.set(true, forKey: notifiedKey)

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
                || settings.authorizationStatus == .ephemeral,
              let lastSuccess else { return }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        let content = UNMutableNotificationContent()
        content.title = LocalizationHelper.localized("Cloud backup is not working")
        content.body = LocalizationHelper.formatted(
            "%1$@ activities have not reached your backup since %2$@.",
            String(unsyncedRideCount),
            formatter.string(from: lastSuccess)
        )
        // .active, not .timeSensitive: it is important and it is not an emergency. Breaking through
        // a Focus mode for a backup that has been failing for three days would be theatre.
        content.interruptionLevel = .active
        content.sound = .default

        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil)
        )
    }
}
