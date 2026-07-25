import XCTest
@testable import track_me_ios

final class UnitFormatterTests: XCTestCase {
    func testMetricDistance() { XCTAssertEqual(UnitFormatter.distance(meters: 1000, unit: .metric), "1.00 km") }
    func testImperialDistance() { XCTAssertEqual(UnitFormatter.distance(meters: 1609.344, unit: .imperial), "1.00 mi") }
    func testMarathonImperialDistance() { XCTAssertEqual(UnitFormatter.distance(meters: 42195, unit: .imperial), "26.22 mi") }
    func testZeroDistancePreservesUnit() {
        XCTAssertEqual(UnitFormatter.distance(meters: 0, unit: .metric), "0.00 km")
        XCTAssertEqual(UnitFormatter.distance(meters: 0, unit: .imperial), "0.00 mi")
    }
    func testMetricSpeed() { XCTAssertEqual(UnitFormatter.speed(mps: 10, unit: .metric), "36.0 km/h") }
    func testImperialSpeed() { XCTAssertEqual(UnitFormatter.speed(mps: 10, unit: .imperial), "22.4 mph") }
}
