import XCTest
@testable import track_me_ios

/// Mirrors Android's AnalyticsManagerConsentTest truth table so the local/remote
/// telemetry contract stays identical across platforms.
final class TelemetryConsentStateTests: XCTestCase {
    func testDefaultOffWithRemoteAllowedIsDisabled() {
        let state = TelemetryConsentState(localConsent: false, remoteAllowed: true)
        XCTAssertFalse(state.isEnabled)
    }

    func testLocalOnWithRemoteAllowedIsEnabled() {
        let state = TelemetryConsentState(localConsent: true, remoteAllowed: true)
        XCTAssertTrue(state.isEnabled)
    }

    func testRemoteKillOverridesLocalOn() {
        let state = TelemetryConsentState(localConsent: true, remoteAllowed: false)
        XCTAssertFalse(state.isEnabled)
    }

    func testLocalOffAlwaysWinsRegardlessOfRemote() {
        XCTAssertFalse(TelemetryConsentState(localConsent: false, remoteAllowed: false).isEnabled)
        XCTAssertFalse(TelemetryConsentState(localConsent: false, remoteAllowed: true).isEnabled)
    }

    func testRemoteReEnableRestoresLocalConsent() {
        XCTAssertFalse(TelemetryConsentState(localConsent: true, remoteAllowed: false).isEnabled)
        XCTAssertTrue(TelemetryConsentState(localConsent: true, remoteAllowed: true).isEnabled)
    }
}
