import XCTest
import CoreLocation
@testable import track_me_ios

final class LocationRecoveryTests: XCTestCase {
    func testDeniedOffersSettingsRecovery() {
        XCTAssertTrue(LocationRecovery.shouldOfferSettingsRecovery(for: .denied))
        XCTAssertTrue(LocationRecovery.shouldOfferSettingsRecovery(for: .restricted))
    }
    func testGrantedOrUndeterminedDoesNotOfferRecovery() {
        XCTAssertFalse(LocationRecovery.shouldOfferSettingsRecovery(for: .authorizedWhenInUse))
        XCTAssertFalse(LocationRecovery.shouldOfferSettingsRecovery(for: .authorizedAlways))
        XCTAssertFalse(LocationRecovery.shouldOfferSettingsRecovery(for: .notDetermined))
    }
}
