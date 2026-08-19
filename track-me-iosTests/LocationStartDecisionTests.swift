import XCTest
@testable import track_me_ios

@MainActor
final class LocationStartDecisionTests: XCTestCase {
    func testActionTruthTable() {
        XCTAssertEqual(LocationStartDecision.action(for: .notDetermined), .requestWhenInUse)
        XCTAssertEqual(LocationStartDecision.action(for: .whenInUse), .begin)
        XCTAssertEqual(LocationStartDecision.action(for: .always), .begin)
        XCTAssertEqual(LocationStartDecision.action(for: .denied), .deniedRecovery)
        XCTAssertEqual(LocationStartDecision.action(for: .restricted), .deniedRecovery)
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
        XCTAssertEqual(LocationStartDecision.action(for: .whenInUse), .begin)
    }

    func testRegressionNotDeterminedRequestsNativePromptImmediately() {
        // A custom pre-permission screen with a deferral path violates App Review 5.1.1(iv).
        XCTAssertEqual(LocationStartDecision.action(for: .notDetermined), .requestWhenInUse)
    }
}
