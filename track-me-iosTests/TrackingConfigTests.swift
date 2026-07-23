import XCTest
@testable import track_me_ios

final class TrackingConfigTests: XCTestCase {
    func testShouldRearmOnInvoluntaryPause() {
        // True for tracking or gpsLost
        XCTAssertTrue(TrackingManager.shouldRearmOnInvoluntaryPause(state: .tracking))
        XCTAssertTrue(TrackingManager.shouldRearmOnInvoluntaryPause(state: .gpsLost))

        // False for idle, paused, storageLow
        XCTAssertFalse(TrackingManager.shouldRearmOnInvoluntaryPause(state: .idle))
        XCTAssertFalse(TrackingManager.shouldRearmOnInvoluntaryPause(state: .paused))
        XCTAssertFalse(TrackingManager.shouldRearmOnInvoluntaryPause(state: .storageLow))
    }
}
