import XCTest
@testable import track_me_ios

final class RideSplitPolicyTests: XCTestCase {

    func testEvaluate() {
        // Below 8,000
        XCTAssertEqual(RideSplitPolicy.evaluate(pointCount: 7999, alreadyWarned: false), .none)
        XCTAssertEqual(RideSplitPolicy.evaluate(pointCount: 7999, alreadyWarned: true), .none)

        // Exactly at 8,000
        XCTAssertEqual(RideSplitPolicy.evaluate(pointCount: 8000, alreadyWarned: false), .warn)
        XCTAssertEqual(RideSplitPolicy.evaluate(pointCount: 8000, alreadyWarned: true), .none)

        // Between 8,001 and 8,999
        XCTAssertEqual(RideSplitPolicy.evaluate(pointCount: 8001, alreadyWarned: true), .none)
        XCTAssertEqual(RideSplitPolicy.evaluate(pointCount: 8999, alreadyWarned: true), .none)

        // At 9,000 and above
        XCTAssertEqual(RideSplitPolicy.evaluate(pointCount: 9000, alreadyWarned: true), .split)
        XCTAssertEqual(RideSplitPolicy.evaluate(pointCount: 9000, alreadyWarned: false), .split)
        XCTAssertEqual(RideSplitPolicy.evaluate(pointCount: 9500, alreadyWarned: true), .split)
    }
}
