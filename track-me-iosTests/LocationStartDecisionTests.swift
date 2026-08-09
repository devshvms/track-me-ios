import XCTest
@testable import track_me_ios

@MainActor
final class LocationStartDecisionTests: XCTestCase {
    func testActionTruthTable() {
        XCTAssertEqual(LocationStartDecision.action(for: .notDetermined, afterPrimer: false), .showPrimer)
        XCTAssertEqual(LocationStartDecision.action(for: .notDetermined, afterPrimer: true), .requestWhenInUse)
        XCTAssertEqual(LocationStartDecision.action(for: .whenInUse, afterPrimer: false), .begin)
        XCTAssertEqual(LocationStartDecision.action(for: .whenInUse, afterPrimer: true), .begin)
        XCTAssertEqual(LocationStartDecision.action(for: .always, afterPrimer: false), .begin)
        XCTAssertEqual(LocationStartDecision.action(for: .always, afterPrimer: true), .begin)
        XCTAssertEqual(LocationStartDecision.action(for: .denied, afterPrimer: false), .deniedRecovery)
        XCTAssertEqual(LocationStartDecision.action(for: .denied, afterPrimer: true), .deniedRecovery)
        XCTAssertEqual(LocationStartDecision.action(for: .restricted, afterPrimer: false), .deniedRecovery)
        XCTAssertEqual(LocationStartDecision.action(for: .restricted, afterPrimer: true), .deniedRecovery)
    }

    func testShouldRequestAlwaysUpgrade() {
        XCTAssertTrue(LocationStartDecision.shouldRequestAlwaysUpgrade(status: .whenInUse, hasAskedAlways: false))
        XCTAssertFalse(LocationStartDecision.shouldRequestAlwaysUpgrade(status: .whenInUse, hasAskedAlways: true))
        XCTAssertFalse(LocationStartDecision.shouldRequestAlwaysUpgrade(status: .always, hasAskedAlways: false))
        XCTAssertFalse(LocationStartDecision.shouldRequestAlwaysUpgrade(status: .always, hasAskedAlways: true))
        XCTAssertFalse(LocationStartDecision.shouldRequestAlwaysUpgrade(status: .denied, hasAskedAlways: false))
        XCTAssertFalse(LocationStartDecision.shouldRequestAlwaysUpgrade(status: .notDetermined, hasAskedAlways: false))
    }

    func testRegressionWhenInUseStartsRide() {
        // WhenInUse must start a ride, never merely re-request Always
        XCTAssertEqual(LocationStartDecision.action(for: .whenInUse, afterPrimer: false), .begin)
    }
}
