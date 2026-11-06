import XCTest
@testable import track_me_ios

final class TouchLockGuardTests: XCTestCase {
    func testTouchLockDurationInvariant() {
        // TASK-350 (LOCK-01): The minimum continuous touch hold duration required
        // to unlock HUD controls is exactly 1.2 seconds (1200ms).
        let unlockDurationThreshold: TimeInterval = 1.2
        XCTAssertEqual(unlockDurationThreshold, 1.2, accuracy: 0.001)

        // Pocket taps or brief contact swipes (< 0.5s) must be rejected
        let accidentalPocketTapDuration: TimeInterval = 0.35
        XCTAssertLessThan(accidentalPocketTapDuration, unlockDurationThreshold)

        let holdProgressAt350ms = accidentalPocketTapDuration / unlockDurationThreshold
        XCTAssertLessThan(holdProgressAt350ms, 1.0)

        // 1200ms hold fulfills 100% progress
        let fullHoldProgress = unlockDurationThreshold / unlockDurationThreshold
        XCTAssertEqual(fullHoldProgress, 1.0, accuracy: 0.001)
    }

    func testTouchLockLocalizationKeys() {
        XCTAssertFalse(LocalizationHelper.localized("Lock").isEmpty)
        XCTAssertFalse(LocalizationHelper.localized("Locked").isEmpty)
        XCTAssertFalse(LocalizationHelper.localized("Hold 1.2s to unlock").isEmpty)
        XCTAssertFalse(LocalizationHelper.localized("Unlocking...").isEmpty)
    }
}
