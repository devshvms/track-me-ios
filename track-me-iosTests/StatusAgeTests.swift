import XCTest
@testable import track_me_ios

final class StatusAgeTests: XCTestCase {
    private let serverNow: Int64 = 1_785_000_000_000
    private let elapsed: Int64 = 500_000

    func testPositionAndStatusAnchorsUseServerAndMonotonicDurations() {
        let position = StatusAge.anchorPosition(
            serverNowMillis: serverNow,
            serverTimestampMillis: serverNow - 8_000,
            receivedAtElapsedMillis: elapsed
        )
        XCTAssertEqual(position.ageAtReceiptMillis, 8_000)
        XCTAssertEqual(StatusAge.currentAgeMillis(anchor: position, nowElapsedMillis: elapsed + 30_000), 38_000)

        let status = StatusAge.anchorStatus(
            serverNowMillis: serverNow,
            serverTimestampMillis: serverNow - 2_000,
            statusAgeSeconds: 420,
            receivedAtElapsedMillis: elapsed
        )
        XCTAssertEqual(status.ageAtReceiptMillis, 422_000)
    }

    func testUnknownStatusAgeStaysUnknown() {
        let anchor = StatusAge.anchorStatus(
            serverNowMillis: serverNow,
            serverTimestampMillis: serverNow,
            statusAgeSeconds: nil,
            receivedAtElapsedMillis: elapsed
        )
        XCTAssertEqual(StatusAge.bucket(anchor: anchor, nowElapsedMillis: elapsed + 3_600_000, syncIntervalSec: 10), .unknown)
    }

    func testAgeBucketsTrackCurrentCadence() {
        XCTAssertEqual(StatusAge.bucket(ageMillis: 9_999, syncIntervalSec: 10), .now)
        XCTAssertEqual(StatusAge.bucket(ageMillis: 25_000, syncIntervalSec: 30), .now)
        XCTAssertEqual(StatusAge.bucket(ageMillis: 25_000, syncIntervalSec: 10), .seconds(25))
        XCTAssertEqual(StatusAge.bucket(ageMillis: 60_000, syncIntervalSec: 10), .minutes(1))
        XCTAssertEqual(StatusAge.bucket(ageMillis: 3_600_000, syncIntervalSec: 10), .hours(1))
    }

    func testBootEpochTolerance() {
        XCTAssertFalse(StatusAge.bootEpochChanged(stored: 1_000_000, current: 1_059_999))
        XCTAssertTrue(StatusAge.bootEpochChanged(stored: 1_000_000, current: 1_060_001))
    }

    func testDeviceWallClockSkewAndChangesCannotMoveAnchoredAge() {
        let anchor = StatusAge.anchorPosition(
            serverNowMillis: serverNow,
            serverTimestampMillis: serverNow - 12_000,
            receivedAtElapsedMillis: elapsed
        )
        let expected = StatusAge.currentAgeMillis(anchor: anchor, nowElapsedMillis: elapsed + 8_000)

        for irrelevantDeviceWallOffset in [-86_400_000, -600_000, 0, 600_000, 86_400_000] as [Int64] {
            _ = serverNow + irrelevantDeviceWallOffset
            XCTAssertEqual(
                StatusAge.currentAgeMillis(anchor: anchor, nowElapsedMillis: elapsed + 8_000),
                expected
            )
        }
        XCTAssertEqual(expected, 20_000)
    }
}
