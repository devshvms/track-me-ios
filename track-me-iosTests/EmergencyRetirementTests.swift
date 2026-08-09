import XCTest
import SwiftData
@testable import track_me_ios

@MainActor
final class EmergencyRetirementTests: XCTestCase {
    func testRetiredEmergencyManagerCannotCreateRideSuppression() {
        let defaults = UserDefaults(suiteName: "EmergencyRetirementTests.\(UUID().uuidString)")!
        let manager = EmergencyManager(defaults: defaults)

        manager.beginRideSession()

        XCTAssertFalse(manager.isEmergencyActive)
        XCTAssertFalse(manager.consumeRideSuppression())
    }

    func testPurgeDeletesLegacyContactsAndSettingsAndShowsNoticeForConfiguredUser() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Ride.self, GPSPoint.self, EmergencyContact.self, EmergencySettings.self,
            configurations: configuration
        )
        let context = container.mainContext
        context.insert(EmergencyContact(name: "Legacy contact", phoneNumber: "+15550100"))
        context.insert(EmergencySettings(isSetupComplete: true))
        try context.save()

        let defaults = UserDefaults(suiteName: "EmergencyRetirementTests.\(UUID().uuidString)")!
        EmergencyDataPurge.shared.purgeOnce(container: container, defaults: defaults)

        XCTAssertTrue(EmergencyDataPurge.shared.shouldShowRemovalNotice)
        XCTAssertEqual(try context.fetch(FetchDescriptor<EmergencyContact>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<EmergencySettings>()).count, 0)

        EmergencyDataPurge.shared.acknowledgeRemovalNotice(defaults: defaults)
        XCTAssertFalse(EmergencyDataPurge.shared.shouldShowRemovalNotice)
    }
}
