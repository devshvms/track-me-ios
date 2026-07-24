import XCTest
@testable import track_me_ios
import SwiftData

@MainActor
final class EmergencySetupLogicTests: XCTestCase {

    static let sharedContainer: ModelContainer = {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try! ModelContainer(for: Ride.self, GPSPoint.self, EmergencyContact.self, EmergencySettings.self, configurations: config)
    }()

    var repository: DataRepository!

    override func setUpWithError() throws {
        repository = DataRepository()
        repository.setup(container: Self.sharedContainer)
    }

    override func tearDownWithError() throws {
        repository = nil
        let context = Self.sharedContainer.mainContext
        if let allSettings = try? context.fetch(FetchDescriptor<EmergencySettings>()) {
            for setting in allSettings { context.delete(setting) }
        }
        if let allContacts = try? context.fetch(FetchDescriptor<EmergencyContact>()) {
            for contact in allContacts { context.delete(contact) }
        }
        try? context.save()
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
        XCTAssertFalse(settings.messageTemplate.isEmpty)
    }

    func testDisableEmergencySetup_SetsFlagToFalse() {
        let settings = repository.getEmergencySettings()
        settings.isSetupComplete = true
        settings.messageTemplate = "Test"
        try? Self.sharedContainer.mainContext.save()

        repository.disableEmergencySetup()

        let fetched = repository.getEmergencySettings()
        XCTAssertFalse(fetched.isSetupComplete)
        XCTAssertEqual(fetched.messageTemplate, "Test")
    }
}
