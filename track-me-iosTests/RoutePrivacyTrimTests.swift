import XCTest
@testable import track_me_ios

final class RoutePrivacyTrimTests: XCTestCase {
    private func point(_ index: Int) -> GPSPoint {
        GPSPoint(
            latitude: 0,
            longitude: Double(index) * 0.001,
            altitude: 0,
            accuracy: 1,
            speed: 1,
            timestamp: Date(timeIntervalSince1970: Double(index))
        )
    }

    func testShortRouteIsReturnedUnchanged() {
        let points = [point(0), point(1)]
        XCTAssertEqual(RoutePrivacyTrim.trim(points, trimMeters: 200_000).map(\.id), points.map(\.id))
    }

    func testLongRouteTrimsBothEndsAndPreservesOrder() {
        let points = (0..<6).map(point)
        let trimmed = RoutePrivacyTrim.trim(points, trimMeters: 100)
        XCTAssertGreaterThan(trimmed.count, 1)
        XCTAssertGreaterThan(trimmed.first!.longitude, points.first!.longitude)
        XCTAssertLessThan(trimmed.last!.longitude, points.last!.longitude)
        XCTAssertEqual(trimmed.map(\.id), Array(points[1...4]).map(\.id))
    }
}
