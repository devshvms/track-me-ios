import Foundation
import UserNotifications

/// SCOPE_1.8.7 §6.1.4 scenario 22 — telling the rider they are still visible to a group.
///
/// The policy is in ``GroupPresenceNotice``; this owns the device half and the "once per group,
/// ever" ledger. That ledger is the only thing between a trust notification and a nuisance, so it
/// is persisted rather than held in memory: a termination between the ride ending and the app being
/// reopened must not turn one notice into two.
///
/// The Android twin is `GroupPresenceNotifier.kt`.
@MainActor
enum GroupPresenceNotifier {

    static let identifier = "trackme.group.still-live"

    private static let noticedKey = "trackme.group.presence.noticed"

    /// Capped, oldest-out. An unbounded list in `UserDefaults` is a slow leak, and a rider who has
    /// been in more than this many groups since the last one will accept being told twice about a
    /// group they left months ago far more readily than an app that stopped launching.
    private static let maxRemembered = 50

    static var noticedGroupIds: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: noticedKey) ?? [])
    }

    /// Evaluates scenario 22 and, if it holds, says so.
    ///
    /// Safe to call more than once — the ledger makes it idempotent per group.
    static func notifyIfStillLive(
        groupId: String?,
        groupName: String?,
        isGroupLive: Bool,
        isRideActive: Bool
    ) async {
        guard GroupPresenceNotice.shouldNotify(
            activeGroupId: groupId,
            isGroupLive: isGroupLive,
            isRideActive: isRideActive,
            alreadyNoticedGroupIds: noticedGroupIds
        ), let groupId else { return }

        remember(groupId)

        // Bulletin first, authorization second — the in-app feed is the surface that has to work for
        // someone who declined notifications, and this row is about a disclosure they are entitled
        // to know about whether or not they let us onto their lock screen.
        var facts: [String: String] = [:]
        if let groupName, !groupName.isEmpty { facts[BulletinEntry.factGroupName] = groupName }
        BulletinStore.shared.add(
            BulletinEntry(
                id: "group-still-live:\(groupId)",
                kind: .groupStillLive,
                createdAtMillis: Int64(Date().timeIntervalSince1970 * 1000),
                facts: facts
            )
        )

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
                || settings.authorizationStatus == .ephemeral else { return }

        let content = UNMutableNotificationContent()
        content.title = LocalizationHelper.localized("You are still sharing with a group")
        if let groupName, !groupName.isEmpty {
            content.body = LocalizationHelper.formatted(
                "Your ride ended, but you are still visible in %@.", groupName
            )
        } else {
            content.body = LocalizationHelper.localized(
                "Your ride ended, but you are still visible in a live group."
            )
        }
        // .active. This is a disclosure the rider should see promptly, but it is not an emergency
        // and staying in a group after a ride is an ordinary thing to be doing.
        content.interruptionLevel = .active

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private static func remember(_ groupId: String) {
        var existing = UserDefaults.standard.stringArray(forKey: noticedKey) ?? []
        existing.removeAll { $0 == groupId }
        existing.append(groupId)
        if existing.count > maxRemembered {
            existing = Array(existing.suffix(maxRemembered))
        }
        UserDefaults.standard.set(existing, forKey: noticedKey)
    }
}
