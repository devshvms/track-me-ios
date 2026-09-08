import XCTest
@testable import track_me_ios

final class AgeSignalManagerTests: XCTestCase {
    func testAdultLowerBoundAllowsAccess() {
        XCTAssertEqual(AgeSignalManager.category(forLowerBound: 18), .adult)
        XCTAssertEqual(AgeSignalManager.category(forLowerBound: 42), .adult)
    }

    func testMinorLowerBoundBlocksAccess() {
        XCTAssertEqual(AgeSignalManager.category(forLowerBound: 17), .minor)
        XCTAssertEqual(AgeSignalManager.category(forLowerBound: 0), .minor)
    }

    func testMissingLowerBoundIsMinorForSharedRange() {
        // Apple's API uses a nil lower bound when the user is below the lowest requested
        // gate. TrackMe requests an 18 gate, so this is a declared minor and must block.
        XCTAssertEqual(AgeSignalManager.category(forLowerBound: nil), .minor)
    }

    @MainActor
    func testDeclinedSharingFailsOpenAndPersistsAllowedDecision() async {
        let defaults = UserDefaults(suiteName: "AgeSignalManagerTests.declined")!
        defaults.removePersistentDomain(forName: "AgeSignalManagerTests.declined")
        let manager = AgeSignalManager(defaults: defaults)

        await manager.checkAndPersist { _ in .noSignal }

        XCTAssertEqual(manager.decision, .allowed)
        XCTAssertEqual(defaults.string(forKey: "ageSignalCategory"), "unknown")
        XCTAssertNotNil(defaults.string(forKey: "ageSignalCheckedAt"))
    }

    @MainActor
    func testRequestErrorFailsOpenAndPersistsAllowedDecision() async {
        let defaults = UserDefaults(suiteName: "AgeSignalManagerTests.error")!
        defaults.removePersistentDomain(forName: "AgeSignalManagerTests.error")
        let manager = AgeSignalManager(defaults: defaults)

        await manager.checkAndPersist { _ in
            struct RequestError: Error {}
            throw RequestError()
        }

        XCTAssertEqual(manager.decision, .allowed)
        XCTAssertEqual(defaults.string(forKey: "ageSignalCategory"), "unknown")
    }
}
