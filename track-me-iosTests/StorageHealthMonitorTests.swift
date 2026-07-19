//
//  StorageHealthMonitorTests.swift
//
//  Boundary coverage for the low-storage policy (parity row 14), mirroring
//  Android's StorageHealthPolicyTest.
//

import XCTest
@testable import track_me_ios

final class StorageHealthMonitorTests: XCTestCase {

    func testAvailableSpaceAtThresholdIsAccepted() {
        // Exactly at the threshold is NOT low (strict less-than).
        XCTAssertFalse(StorageHealthMonitor.isLowStorage(availableBytes: StorageHealthMonitor.lowStorageThresholdBytes))
    }

    func testSpaceBelowThresholdIsRejected() {
        XCTAssertTrue(StorageHealthMonitor.isLowStorage(availableBytes: StorageHealthMonitor.lowStorageThresholdBytes - 1))
    }

    func testAmpleSpaceIsAccepted() {
        XCTAssertFalse(StorageHealthMonitor.isLowStorage(availableBytes: 5 * 1024 * 1024 * 1024))
    }

    func testCustomThresholdIsHonored() {
        let threshold: Int64 = 10 * 1024 * 1024
        XCTAssertTrue(StorageHealthMonitor.isLowStorage(availableBytes: threshold - 1, threshold: threshold))
        XCTAssertFalse(StorageHealthMonitor.isLowStorage(availableBytes: threshold, threshold: threshold))
    }
}
