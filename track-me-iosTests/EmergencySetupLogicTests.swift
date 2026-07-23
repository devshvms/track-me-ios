import XCTest
@testable import track_me_ios


final class EmergencySetupLogicTests: XCTestCase {

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
}
