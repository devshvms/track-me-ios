import Foundation
import Observation
import SwiftData

/// One-time upgrade cleanup for the retired emergency contacts/SMS feature.
///
/// The legacy SwiftData models remain in the schema for this release so an existing store can
/// open safely. This purge deletes their rows before any new UI can reach them; a later schema
/// migration can remove the compatibility models once this release has shipped.
@Observable
@MainActor
final class EmergencyDataPurge {
    static let shared = EmergencyDataPurge()

    private let purgeKey = "emergency_data_purged_v165_ios"
    private let noticeEvaluatedKey = "emergency_removal_notice_evaluated_v165_ios"
    private let noticePendingKey = "emergency_removal_notice_pending_ios"

    var shouldShowRemovalNotice = false

    private init() {}

    func purgeOnce(container: ModelContainer, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: purgeKey) else {
            shouldShowRemovalNotice = defaults.bool(forKey: noticePendingKey)
            EmergencyManager.shared.clearLegacyState()
            return
        }

        let context = ModelContext(container)
        do {
            let settings = try context.fetch(FetchDescriptor<EmergencySettings>())
            let hadCompletedSetup = settings.contains { $0.isSetupComplete }

            try context.delete(model: EmergencyContact.self)
            try context.delete(model: EmergencySettings.self)
            try context.save()

            defaults.set(true, forKey: purgeKey)
            if !defaults.bool(forKey: noticeEvaluatedKey) {
                defaults.set(true, forKey: noticeEvaluatedKey)
                defaults.set(hadCompletedSetup, forKey: noticePendingKey)
            }
            shouldShowRemovalNotice = defaults.bool(forKey: noticePendingKey)
            EmergencyManager.shared.clearLegacyState()
        } catch {
            // Keep the guard unset so the next launch can retry instead of silently losing the
            // notice or leaving stale emergency records behind.
            NSLog("TrackMe: retired emergency data purge failed: %@", error.localizedDescription)
        }
    }

    func acknowledgeRemovalNotice(defaults: UserDefaults = .standard) {
        shouldShowRemovalNotice = false
        defaults.set(false, forKey: noticePendingKey)
    }
}
