import XCTest
@testable import track_me_ios
import SwiftData

@MainActor
final class EmergencySetupLogicTests: XCTestCase {

    var container: ModelContainer!
    var repository: DataRepository!

    override func setUpWithError() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Ride.self, GPSPoint.self, EmergencyContact.self, EmergencySettings.self, configurations: config)
        repository = DataRepository()
        repository.setup(container: container)
    }

    override func tearDownWithError() throws {
        container = nil
        repository = nil
    }

    func testSetupComplete_TrueWhenFlagAndContacts() {
        XCTAssertTrue(EmergencySetupLogic.isSetupComplete(isSetupComplete: true, contactCount: 1))
        XCTAssertTrue(EmergencySetupLogic.isSetupComplete(isSetupComplete: true, contactCount: 3))
    }

    func testSetupComplete_FalseWhenNoContacts() {
        XCTAssertFalse(EmergencySetupLogic.isSetupComplete(isSetupComplete: true, contactCount: 0))
    }

    func testSetupComplete_FalseWhenFlagIsFalse() {
        XCTAssertFalse(EmergencySetupLogic.isSetupComplete(isSetupComplete: false, contactCount: 1))
        XCTAssertFalse(EmergencySetupLogic.isSetupComplete(isSetupComplete: false, contactCount: 0))
    }

    func testGetEmergencySettings_CreatesDefaultIfNotExists() {
        let settings = repository.getEmergencySettings()
        XCTAssertFalse(settings.isSetupComplete)
        XCTAssertEqual(settings.customMessage, "")
    }

    func testDisableEmergencySetup_SetsFlagToFalse() {
        let settings = repository.getEmergencySettings()
        settings.isSetupComplete = true
        settings.customMessage = "Test"
        try? container.mainContext.save()

        repository.disableEmergencySetup()

        let fetched = repository.getEmergencySettings()
        XCTAssertFalse(fetched.isSetupComplete)
        XCTAssertEqual(fetched.customMessage, "Test")
    }
}
