import XCTest
import CoreLocation
@testable import track_me_ios

/// TASK-246. The History card's route shape is persisted data, so the codec has to round-trip
/// within the precision it claims and survive strings an older or truncated build could have
/// written — a thumbnail is never worth taking the list down for.
final class RoutePolylineTests: XCTestCase {

    private func point(_ latitude: Double, _ longitude: Double) -> HomeDashboardRoutePoint {
        HomeDashboardRoutePoint(latitude: latitude, longitude: longitude)
    }

    func testRoundTripPreservesCoordinatesToFiveDecimalPlaces() {
        let original = [
            point(12.97160, 77.59460),
            point(12.97220, 77.59510),
            point(12.97315, 77.59602),
            point(12.97401, 77.59688),
        ]

        let decoded = RoutePolyline.decode(RoutePolyline.encode(original))

        XCTAssertEqual(decoded.count, original.count)
        for (index, coordinate) in decoded.enumerated() {
            // 1e-5 degrees is the encoding's stated precision, roughly a metre. Asserting tighter
            // would be asserting against the format rather than against this implementation.
            XCTAssertEqual(coordinate.latitude, original[index].latitude, accuracy: 1e-5)
            XCTAssertEqual(coordinate.longitude, original[index].longitude, accuracy: 1e-5)
        }
    }

    func testNegativeAndCrossingCoordinatesSurviveTheRoundTrip() {
        // Zig-zag encoding is the part most likely to be wrong, and it only shows on negatives.
        let original = [
            point(-33.86880, 151.20930),
            point(-33.87010, 151.21150),
            point(-33.86790, 151.20880),
        ]

        let decoded = RoutePolyline.decode(RoutePolyline.encode(original))

        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded[0].latitude, -33.86880, accuracy: 1e-5)
        XCTAssertEqual(decoded[2].longitude, 151.20880, accuracy: 1e-5)
    }

    func testATruncatedStringDecodesToWhatItCanRatherThanCrashing() {
        let full = RoutePolyline.encode([
            point(12.97160, 77.59460),
            point(12.97220, 77.59510),
            point(12.97315, 77.59602),
        ])
        let truncated = String(full.dropLast(2))

        // The contract is "return what is readable", not "return everything" — the card falls back
        // to the glyph when fewer than two points come back.
        let decoded = RoutePolyline.decode(truncated)
        XCTAssertLessThanOrEqual(decoded.count, 3)
    }

    func testGarbageDecodesEmptyInsteadOfSpinning() {
        XCTAssertTrue(RoutePolyline.decode("!!!").isEmpty)
        XCTAssertTrue(RoutePolyline.decode("").isEmpty)
        // A run of continuation bytes that never terminates must not shift forever.
        XCTAssertTrue(RoutePolyline.decode(String(repeating: "\u{7E}", count: 64)).count < 8)
    }

    func testFewerThanTwoPointsHasNoShapeToStore() {
        XCTAssertNil(RoutePolyline.encoded(from: []))
    }

    // MARK: - shvm's threshold

    func testARealRideDrawsItsShape() {
        XCTAssertTrue(RouteThumbnailPolicy.drawsShape(pointCount: 1_200, distanceMeters: 18_900))
    }

    func testThePointThresholdIsInclusiveAtItsBoundary() {
        XCTAssertFalse(
            RouteThumbnailPolicy.drawsShape(
                pointCount: RouteThumbnailPolicy.minimumPoints - 1,
                distanceMeters: 500
            ),
            "49 points is below the bar"
        )
        XCTAssertTrue(
            RouteThumbnailPolicy.drawsShape(
                pointCount: RouteThumbnailPolicy.minimumPoints,
                distanceMeters: 500
            ),
            "50 points is the bar, not past it"
        )
    }

    func testARideThatNeverMovedFallsBackHoweverManyPointsItLogged() {
        // Standing at a light with GPS running: thousands of samples, no distance. Drawing that
        // normalises against a zero span and produces a dot that reads as a broken thumbnail.
        XCTAssertFalse(RouteThumbnailPolicy.drawsShape(pointCount: 5_000, distanceMeters: 0))
    }

    func testNoPointsNeverDraws() {
        XCTAssertFalse(RouteThumbnailPolicy.drawsShape(pointCount: 0, distanceMeters: 0))
        XCTAssertFalse(
            RouteThumbnailPolicy.drawsShape(pointCount: 0, distanceMeters: 9_000),
            "distance without points cannot be drawn either"
        )
    }

    func testTheTwoPlatformsAgreeOnTheThreshold() {
        // Android's ROUTE_THUMBNAIL_MIN_POINTS. If one side moves, this is the reminder.
        XCTAssertEqual(RouteThumbnailPolicy.minimumPoints, 50)
        XCTAssertEqual(RoutePolyline.maxPoints, 40, "matches DASHBOARD_ROUTE_POLYLINE_POINTS")
    }
}
