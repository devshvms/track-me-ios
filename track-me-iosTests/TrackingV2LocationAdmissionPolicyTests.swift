import CoreLocation
import XCTest
@testable import track_me_ios

final class TrackingV2LocationAdmissionPolicyTests: XCTestCase {
    private let coordinate = CLLocationCoordinate2D(latitude: 12.9716, longitude: 77.5946)

    func testDelayedRideOwnedFixIsAccepted() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(TrackingV2LocationAdmissionPolicy.accepts(
            timestamp: start.addingTimeInterval(30),
            coordinate: coordinate,
            horizontalAccuracy: 8,
            eligibleAfter: start,
            lastAcceptedAt: start.addingTimeInterval(20),
            now: start.addingTimeInterval(300)
        ))
    }

    func testPreSessionAndNonMonotonicFixesAreRejected() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(TrackingV2LocationAdmissionPolicy.accepts(
            timestamp: start.addingTimeInterval(-2),
            coordinate: coordinate,
            horizontalAccuracy: 8,
            eligibleAfter: start,
            lastAcceptedAt: nil,
            now: start
        ))
        XCTAssertFalse(TrackingV2LocationAdmissionPolicy.accepts(
            timestamp: start.addingTimeInterval(10),
            coordinate: coordinate,
            horizontalAccuracy: 8,
            eligibleAfter: start,
            lastAcceptedAt: start.addingTimeInterval(10),
            now: start.addingTimeInterval(11)
        ))
    }

    func testFutureInvalidCoordinateAndInvalidAccuracyAreRejected() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(TrackingV2LocationAdmissionPolicy.accepts(
            timestamp: start.addingTimeInterval(2),
            coordinate: coordinate,
            horizontalAccuracy: 8,
            eligibleAfter: start,
            lastAcceptedAt: nil,
            now: start
        ))
        XCTAssertFalse(TrackingV2LocationAdmissionPolicy.accepts(
            timestamp: start,
            coordinate: CLLocationCoordinate2D(latitude: 91, longitude: 0),
            horizontalAccuracy: 8,
            eligibleAfter: start,
            lastAcceptedAt: nil,
            now: start
        ))
        XCTAssertFalse(TrackingV2LocationAdmissionPolicy.accepts(
            timestamp: start,
            coordinate: coordinate,
            horizontalAccuracy: -1,
            eligibleAfter: start,
            lastAcceptedAt: nil,
            now: start
        ))
    }
}
