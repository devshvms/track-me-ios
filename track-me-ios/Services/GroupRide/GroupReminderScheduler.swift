import Foundation
import UserNotifications

enum GroupReminderScheduler {
    private static let identifier = "groupRide.scheduledStart"

    static func schedule(groupId: String, groupName: String, startAtMillis: Int64?) {
        cancel()
        guard let startAtMillis else { return }
        let start = Date(timeIntervalSince1970: TimeInterval(startAtMillis) / 1000)
        let reminder = start.addingTimeInterval(-15 * 60)
        guard reminder > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = groupName
        content.body = "Your group ride starts in 15 minutes. Sharing starts only when the leader taps Start."
        content.sound = .default
        content.userInfo = ["groupId": groupId]

        let components = Calendar.current.dateComponents(
            [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second],
            from: reminder
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}
