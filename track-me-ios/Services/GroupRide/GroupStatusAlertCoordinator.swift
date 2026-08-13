import Foundation
import UserNotifications
import UIKit

@MainActor
final class GroupStatusAlertCoordinator {
    static let shared = GroupStatusAlertCoordinator()

    static let categoryIdentifier = "group_status_alerts"
    static let resolutionCategoryIdentifier = "group_status_resolution"
    static let viewActionIdentifier = "group_status_view"
    static let muteActionIdentifier = "group_status_mute"
    static let notificationPrefix = "group_status_member_"

    private let store: GroupSessionStore

    init(store: GroupSessionStore? = nil) {
        self.store = store ?? .shared
    }

    func registerNotificationCategory() {
        let view = UNNotificationAction(
            identifier: Self.viewActionIdentifier,
            title: LocalizationHelper.localized("View group"),
            options: [.foreground]
        )
        let mute = UNNotificationAction(
            identifier: Self.muteActionIdentifier,
            title: LocalizationHelper.localized("Mute alerts"),
            options: []
        )
        let alertCategory = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [view, mute],
            intentIdentifiers: [],
            options: []
        )
        let resolutionCategory = UNNotificationCategory(
            identifier: Self.resolutionCategoryIdentifier,
            actions: [view],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([alertCategory, resolutionCategory])
    }

    func removeSessionNotifications() {
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let deliveredIdentifiers = await center.deliveredNotifications()
                .map(\.request.identifier)
                .filter { $0.hasPrefix(Self.notificationPrefix) }
            center.removeDeliveredNotifications(withIdentifiers: deliveredIdentifiers)

            let pendingIdentifiers = await center.pendingNotificationRequests()
                .map(\.identifier)
                .filter { $0.hasPrefix(Self.notificationPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: pendingIdentifiers)
        }
    }

    func process(
        previous: [GroupWire.MemberStatus],
        current: [GroupWire.MemberStatus],
        positions: [GroupWire.MemberPosition],
        roster: [GroupWire.RosterEntry],
        groupName: String?,
        joinedAtElapsedMillis: Int64,
        syncIntervalSec: Int,
        alertsMuted: Bool
    ) {
        let originalLedger = store.load()?.record.shownAlertStatuses ?? [:]
        let nowElapsed = StatusAge.elapsedMillis()
        let freshUIDs = Set(positions.compactMap { position in
            isFresh(
                position: position,
                nowElapsed: nowElapsed,
                syncIntervalSec: syncIntervalSec
            ) ? position.uid : nil
        })
        let decision = GroupStatusAlertPolicy.evaluate(
            previous: previous,
            current: current,
            freshUIDs: freshUIDs,
            shownLedger: originalLedger,
            elapsedSinceJoinMillis: max(0, nowElapsed - joinedAtElapsedMillis),
            alertsMuted: alertsMuted
        )

        for transition in decision.alerts {
            presentAlert(
                uid: transition.uid,
                name: memberName(uid: transition.uid, roster: roster),
                status: transition.status,
                groupName: groupName
            )
        }
        for transition in decision.resolutions {
            presentResolution(
                uid: transition.uid,
                name: memberName(uid: transition.uid, roster: roster),
                status: transition.status,
                groupName: groupName
            )
        }
        let presentedResolutionUIDs = Set(decision.resolutions.map(\.uid))
        let silentlyResolvedUIDs = Set(originalLedger.keys)
            .subtracting(decision.ledger.keys)
            .subtracting(presentedResolutionUIDs)
        if !silentlyResolvedUIDs.isEmpty {
            UNUserNotificationCenter.current().removeDeliveredNotifications(
                withIdentifiers: silentlyResolvedUIDs.map { notificationIdentifier(uid: $0) }
            )
        }
        for uid in Set(originalLedger.keys).union(decision.ledger.keys) {
            let before = originalLedger[uid]
            let after = decision.ledger[uid]
            if before != after {
                store.updateShownAlertStatus(after, for: uid)
            }
        }
    }

    private func isFresh(
        position: GroupWire.MemberPosition,
        nowElapsed: Int64,
        syncIntervalSec: Int
    ) -> Bool {
        guard let anchor = position.ageAnchor else { return false }
        let age = StatusAge.currentAgeMillis(anchor: anchor, nowElapsedMillis: nowElapsed)
        return age < Int64(max(20, syncIntervalSec * 2)) * 1_000
    }

    private func memberName(uid: String, roster: [GroupWire.RosterEntry]) -> String {
        let entry = roster.first { $0.uid == uid }
        return entry?.displayName ?? entry?.initials ?? LocalizationHelper.localized("Rider")
    }

    private func presentAlert(uid: String, name: String, status: RiderStatus, groupName: String?) {
        if UIApplication.shared.applicationState == .active {
            strongHaptic()
        } else {
            let content = UNMutableNotificationContent()
            content.title = groupName ?? LocalizationHelper.localized("Group Ride")
            content.body = LocalizationHelper.formatted(
                "%@ set their status to %@",
                name,
                RiderStatusPresentation.label(for: status)
            )
            content.sound = .default
            // Use the existing notification permission; 1.7.2 deliberately adds
            // no Time Sensitive capability or permission surface.
            content.interruptionLevel = .active
            content.categoryIdentifier = Self.categoryIdentifier
            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: notificationIdentifier(uid: uid),
                content: content,
                trigger: nil
            ))
        }
        TelemetryManager.shared.trackGroupStatusAlertShown()
    }

    private func presentResolution(uid: String, name: String, status: RiderStatus, groupName: String?) {
        if UIApplication.shared.applicationState == .active {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } else {
            let content = UNMutableNotificationContent()
            content.title = groupName ?? LocalizationHelper.localized("Group Ride")
            content.body = LocalizationHelper.formatted(
                "%@ cleared %@",
                name,
                RiderStatusPresentation.label(for: status)
            )
            content.interruptionLevel = .active
            content.categoryIdentifier = Self.resolutionCategoryIdentifier
            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: notificationIdentifier(uid: uid),
                content: content,
                trigger: nil
            ))
        }
        TelemetryManager.shared.trackGroupStatusAlertDismissed()
    }

    private func strongHaptic() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.warning)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            generator.notificationOccurred(.warning)
        }
    }

    private func notificationIdentifier(uid: String) -> String {
        Self.notificationPrefix + uid
    }
}
