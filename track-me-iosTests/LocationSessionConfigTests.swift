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

    func testPersonaTunesCoreLocationForMovementType() {
        XCTAssertEqual(TrackingManager.activityType(for: .auto), .fitness)
        XCTAssertEqual(TrackingManager.activityType(for: .walk), .fitness)
        XCTAssertEqual(TrackingManager.activityType(for: .run), .fitness)
        XCTAssertEqual(TrackingManager.activityType(for: .cycling), .otherNavigation)
        XCTAssertEqual(TrackingManager.activityType(for: .bikeDrive), .automotiveNavigation)
        XCTAssertEqual(TrackingManager.activityType(for: .carDrive), .automotiveNavigation)
    }
}
