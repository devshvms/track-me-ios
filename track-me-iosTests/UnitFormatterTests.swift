import XCTest
@testable import track_me_ios

final class UnitFormatterTests: XCTestCase {
    func testMetricDistance() { XCTAssertEqual(UnitFormatter.distance(meters: 1000, unit: .metric), "1.00 km") }
    func testImperialDistance() { XCTAssertEqual(UnitFormatter.distance(meters: 1609.344, unit: .imperial), "1.00 mi") }
    func testMetricSpeed() { XCTAssertEqual(UnitFormatter.speed(mps: 10, unit: .metric), "36.0 km/h") }
    func testImperialSpeed() { XCTAssertEqual(UnitFormatter.speed(mps: 10, unit: .imperial), "22.4 mph") }
}
