import XCTest
@testable import track_me_ios

final class ReplayExportConfigTests: XCTestCase {
    func testDefaultsMatchAndroidContract() throws {
        let config = try ReplayExportConfig(persona: .walk)
        XCTAssertEqual(config.width, 1080)
        XCTAssertEqual(config.height, 1920)
        XCTAssertEqual(config.fps, 30)
        XCTAssertEqual(config.targetDurationSeconds, 20)
        XCTAssertTrue(config.applyPrivacyTrim)
        XCTAssertEqual(config.privacyTrimDistanceMeters, 200)
        XCTAssertNil(config.deepLink)
    }

    func testRejectsInvalidBounds() {
        XCTAssertThrowsError(try ReplayExportConfig(width: 0, persona: .walk)) { error in
            XCTAssertEqual(error as? ReplayExportConfigError, .invalidDimensions)
        }
        XCTAssertThrowsError(try ReplayExportConfig(fps: 61, persona: .walk)) { error in
            XCTAssertEqual(error as? ReplayExportConfigError, .invalidFrameRate)
        }
        XCTAssertThrowsError(try ReplayExportConfig(targetDurationSeconds: 14, persona: .walk)) { error in
            XCTAssertEqual(error as? ReplayExportConfigError, .invalidDuration)
        }
        XCTAssertThrowsError(try ReplayExportConfig(privacyTrimDistanceMeters: -1, persona: .walk)) { error in
            XCTAssertEqual(error as? ReplayExportConfigError, .invalidPrivacyTrim)
        }
    }
}
