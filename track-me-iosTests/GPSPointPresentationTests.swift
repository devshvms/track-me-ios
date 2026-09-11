import CoreLocation
import XCTest
@testable import track_me_ios

final class GPSPointPresentationTests: XCTestCase {
    private func point(displayLatitude: Double?, displayLongitude: Double?) -> GPSPoint {
        GPSPoint(
            latitude: 12,
            longitude: 77,
            altitude: 0,
            accuracy: 5,
            speed: 1,
            timestamp: Date(timeIntervalSince1970: 1),
            displayLatitude: displayLatitude,
            displayLongitude: displayLongitude
        )
    }

    func testValidV2DisplayCoordinateIsUsedWithoutChangingRawEvidence() {
        let point = point(displayLatitude: 13, displayLongitude: 78)
        XCTAssertEqual(point.coordinate.latitude, 13)
        XCTAssertEqual(point.coordinate.longitude, 78)
        XCTAssertEqual(point.latitude, 12)
        XCTAssertEqual(point.longitude, 77)
    }

    func testIncompleteOrInvalidDisplayCoordinateFallsBackToRaw() {
        XCTAssertEqual(point(displayLatitude: 13, displayLongitude: nil).coordinate.latitude, 12)
        XCTAssertEqual(point(displayLatitude: 91, displayLongitude: 78).coordinate.latitude, 12)
    }

    func testCloudPayloadKeepsRawAndPresentationCoordinatesSeparate() {
        let payload = FirestoreSyncManager.pointPayload(
            point(displayLatitude: 13, displayLongitude: 78)
        )
        XCTAssertEqual(payload["lat"] as? Double, 12)
        XCTAssertEqual(payload["lng"] as? Double, 77)
        XCTAssertEqual(payload["displayLat"] as? Double, 13)
        XCTAssertEqual(payload["displayLng"] as? Double, 78)
    }
}
