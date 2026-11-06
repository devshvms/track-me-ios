//
//  RecoveryTelemetryTests.swift
//
//  TASK-356. Recovery telemetry stays coarse and silent when recovery did nothing.
//

import XCTest
@testable import track_me_ios

final class RecoveryTelemetryTests: XCTestCase {

    func testDistanceBucketsSplitAtOneFiveAndTwentyKm() {
        XCTAssertEqual(RecoveryTelemetry.distanceBucket(totalMeters: 0), "lt_1km")
        XCTAssertEqual(RecoveryTelemetry.distanceBucket(totalMeters: 999.9), "lt_1km")
        XCTAssertEqual(RecoveryTelemetry.distanceBucket(totalMeters: 1_000), "1_5km")
        XCTAssertEqual(RecoveryTelemetry.distanceBucket(totalMeters: 4_999), "1_5km")
        XCTAssertEqual(RecoveryTelemetry.distanceBucket(totalMeters: 5_000), "5_20km")
        XCTAssertEqual(RecoveryTelemetry.distanceBucket(totalMeters: 20_000), "gte_20km")
        XCTAssertEqual(RecoveryTelemetry.distanceBucket(totalMeters: 250_000), "gte_20km")
    }

    func testPropertiesCarryCountsAndABucketOnly() {
        let props = RecoveryTelemetry.properties(recoveredCount: 2, discardedCount: 1, totalMeters: 12_300)
        XCTAssertEqual(Set(props.keys), ["recovered_count", "discarded_count", "distance_bucket"])
        XCTAssertEqual(props["recovered_count"] as? Int, 2)
        XCTAssertEqual(props["discarded_count"] as? Int, 1)
        XCTAssertEqual(props["distance_bucket"] as? String, "5_20km")
    }

    func testNoPropertyCanLeakARawDistanceIdOrTitle() {
        let keys = Set(RecoveryTelemetry.properties(recoveredCount: 1, discardedCount: 0, totalMeters: 4_321).keys)
        for forbidden in ["ride_id", "title", "distance_meters", "latitude", "longitude", "timestamp"] {
            XCTAssertFalse(keys.contains(forbidden), "forbidden property \(forbidden)")
        }
    }

    func testReportsOnlyWhenRecoveryChangedSomething() {
        XCTAssertFalse(RecoveryTelemetry.shouldReport(recoveredCount: 0, discardedCount: 0))
        XCTAssertTrue(RecoveryTelemetry.shouldReport(recoveredCount: 1, discardedCount: 0))
        XCTAssertTrue(RecoveryTelemetry.shouldReport(recoveredCount: 0, discardedCount: 3))
    }
}
