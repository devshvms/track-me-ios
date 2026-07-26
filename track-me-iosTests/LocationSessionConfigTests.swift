import CoreLocation
import XCTest
@testable import track_me_ios

final class LocationSessionConfigTests: XCTestCase {
    func testRecordingRidePreservesRouteFidelityAndOwnsPauseDetection() {
        let config = LocationSessionConfig.recordingRide

        XCTAssertEqual(config.desiredAccuracy, kCLLocationAccuracyBest)
        XCTAssertEqual(config.distanceFilter, 2)
        XCTAssertTrue(config.allowsBackgroundLocationUpdates)
        XCTAssertTrue(config.showsBackgroundLocationIndicator)
        XCTAssertEqual(config.activityType, .fitness)
        XCTAssertFalse(config.pausesLocationUpdatesAutomatically)
    }
}
