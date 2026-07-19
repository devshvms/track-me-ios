//
//  ChartAccessibilityTests.swift
//
//  NOTE: This project has no unit-test target yet. To run these tests:
//    1. In Xcode: File ▸ New ▸ Target… ▸ Unit Testing Bundle (name it
//       "track-me-iosTests"), host application = track-me-ios.
//    2. Add this file to that target's "Compile Sources".
//    3. Add `ChartAccessibility.swift`/`ChartSample` to the app target (they
//       already are, via the synchronized group) and keep `@testable import`.
//
//  Mirrors Android's `ChartAccessibilityTest.kt` (commit e0feadb): empty input,
//  a single gap, multiple gaps, and average-speed / altitude formatting.
//

import XCTest
@testable import track_me_ios

final class ChartAccessibilityTests: XCTestCase {

    private func sample(_ secondsFromStart: TimeInterval,
                        speed: Double,
                        altitude: Double) -> ChartSample {
        ChartSample(timestamp: Date(timeIntervalSince1970: secondsFromStart),
                    speedMetersPerSecond: speed,
                    altitudeMeters: altitude)
    }

    func testEmptyPointsReportsNoData() {
        let description = ChartAccessibility.description(for: [])
        XCTAssertEqual(description, "Speed and altitude chart. No GPS data available.")
    }

    func testNoGapsWhenSamplesAreClose() {
        let samples = [
            sample(0, speed: 5, altitude: 100),
            sample(10, speed: 5, altitude: 110),
            sample(20, speed: 5, altitude: 120)
        ]
        let description = ChartAccessibility.description(for: samples)
        XCTAssertTrue(description.contains("No GPS signal gaps."), description)
    }

    func testSingleGapUsesSingularSentence() {
        let samples = [
            sample(0, speed: 5, altitude: 100),
            sample(60, speed: 5, altitude: 100) // 60s > 25s threshold
        ]
        let description = ChartAccessibility.description(for: samples)
        XCTAssertTrue(description.contains("1 GPS signal gap."), description)
        XCTAssertFalse(description.contains("1 GPS signal gaps."), description)
    }

    func testMultipleGapsAreCounted() {
        let samples = [
            sample(0, speed: 5, altitude: 100),
            sample(40, speed: 5, altitude: 100),  // gap 1
            sample(80, speed: 5, altitude: 100),  // gap 2
            sample(200, speed: 5, altitude: 100)  // gap 3
        ]
        let description = ChartAccessibility.description(for: samples)
        XCTAssertTrue(description.contains("3 GPS signal gaps."), description)
    }

    func testAverageSpeedIsMetersPerSecondTimes3Point6() {
        // Mean speed 10 m/s -> 36.0 km/h.
        let samples = [
            sample(0, speed: 8, altitude: 50),
            sample(10, speed: 12, altitude: 60)
        ]
        let description = ChartAccessibility.description(for: samples)
        XCTAssertTrue(description.contains("36.0 kilometers per hour"), description)
    }

    func testAltitudeRangeIsMinToMax() {
        let samples = [
            sample(0, speed: 5, altitude: 12.4),
            sample(10, speed: 5, altitude: 88.9),
            sample(20, speed: 5, altitude: 40.0)
        ]
        let description = ChartAccessibility.description(for: samples)
        XCTAssertTrue(description.contains("from 12 to 89 meters"), description)
    }
}
