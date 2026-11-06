import XCTest
@testable import track_me_ios

/// Mirrors Android's AnalyticsManagerConsentTest truth table so the local/remote
/// telemetry contract stays identical across platforms.
///
/// TASK-250 added a third term. These cases are about consent and the remote switch, so they hold
/// the environment open to keep testing what they were written to test; the environment term has
/// its own cases below.
final class TelemetryConsentStateTests: XCTestCase {
    func testDefaultOffWithRemoteAllowedIsDisabled() {
        let state = TelemetryConsentState(localConsent: false, remoteAllowed: true, environmentAllowsDelivery: true)
        XCTAssertFalse(state.isEnabled)
    }

    func testLocalOnWithRemoteAllowedIsEnabled() {
        let state = TelemetryConsentState(localConsent: true, remoteAllowed: true, environmentAllowsDelivery: true)
        XCTAssertTrue(state.isEnabled)
    }

    func testRemoteKillOverridesLocalOn() {
        let state = TelemetryConsentState(localConsent: true, remoteAllowed: false, environmentAllowsDelivery: true)
        XCTAssertFalse(state.isEnabled)
    }

    func testLocalOffAlwaysWinsRegardlessOfRemote() {
        XCTAssertFalse(TelemetryConsentState(localConsent: false, remoteAllowed: false, environmentAllowsDelivery: true).isEnabled)
        XCTAssertFalse(TelemetryConsentState(localConsent: false, remoteAllowed: true, environmentAllowsDelivery: true).isEnabled)
    }

    func testRemoteReEnableRestoresLocalConsent() {
        XCTAssertFalse(TelemetryConsentState(localConsent: true, remoteAllowed: false, environmentAllowsDelivery: true).isEnabled)
        XCTAssertTrue(TelemetryConsentState(localConsent: true, remoteAllowed: true, environmentAllowsDelivery: true).isEnabled)
    }

    // MARK: - TASK-250, the environment gate

    func testTheEnvironmentTermCanOnlyEverSubtract() {
        // It must never grant delivery consent did not.
        for environment in [true, false] {
            XCTAssertFalse(
                TelemetryConsentState(localConsent: false, remoteAllowed: true, environmentAllowsDelivery: environment).isEnabled
            )
            XCTAssertFalse(
                TelemetryConsentState(localConsent: true, remoteAllowed: false, environmentAllowsDelivery: environment).isEnabled
            )
        }
        XCTAssertFalse(
            TelemetryConsentState(localConsent: true, remoteAllowed: true, environmentAllowsDelivery: false).isEnabled,
            "consent alone is not enough from a debug build"
        )
        XCTAssertTrue(
            TelemetryConsentState(localConsent: true, remoteAllowed: true, environmentAllowsDelivery: true).isEnabled
        )
    }

    func testThisTestRunIsItselfSuppressed() {
        // The tests run in the Simulator, and under DEBUG, so the gate must be closed right here.
        // This is the one assertion that checks the real compiled value rather than a passed-in
        // one -- if the #if conditions were ever inverted, every other case would still pass.
        XCTAssertFalse(TelemetryEnvironment.allowsDelivery)
        XCTAssertNotNil(TelemetryEnvironment.suppressionReason)
    }

    // MARK: - TASK-331, cross-platform screen_name and ride_completed parity

    func testNormalizeScreenNameMatchesAndroidRouteNames() {
        XCTAssertEqual(TelemetryManager.normalizeScreenName("HomeView"), "home")
        XCTAssertEqual(TelemetryManager.normalizeScreenName("home"), "home")
        XCTAssertEqual(TelemetryManager.normalizeScreenName("HistoryView"), "history")
        XCTAssertEqual(TelemetryManager.normalizeScreenName("SettingsView"), "settings")
        XCTAssertEqual(TelemetryManager.normalizeScreenName("RideDetailView"), "ride_detail")
        XCTAssertEqual(TelemetryManager.normalizeScreenName("ride_detail/{rideId}"), "ride_detail")
        XCTAssertEqual(TelemetryManager.normalizeScreenName("AccountManagementView"), "account_management")
        XCTAssertEqual(TelemetryManager.normalizeScreenName("CommunityView"), "community")
        XCTAssertEqual(TelemetryManager.normalizeScreenName("GamificationCollectionScreen"), "gamification_progress")
        XCTAssertEqual(TelemetryManager.normalizeScreenName("HelpFeedbackView"), "help_feedback")
        XCTAssertEqual(TelemetryManager.normalizeScreenName("BulletinView"), "bulletin")
    }

    func testRideCompletedPropertiesIncludeDurationAndDistanceWithoutRideId() {
        let props = TelemetryManager.rideCompletedProperties(durationSeconds: 1845, distanceKm: 12.34)
        XCTAssertEqual(props["duration_seconds"] as? Int64, 1845)
        XCTAssertEqual(props["distance_km"] as? Double, 12.34)
        XCTAssertNil(props["ride_id"], "ride_id must remain omitted per Scope 1.7.3 §0.8")
    }

    func testCrashlyticsErrorLoggerFiltersExpectedFirestoreAndCancellationErrors() {
        XCTAssertFalse(CrashlyticsErrorLogger.isReportable(CancellationError()))
        let permDenied = NSError(domain: "FIRFirestoreErrorDomain", code: 7)
        let unavailable = NSError(domain: "FIRFirestoreErrorDomain", code: 14)
        let internalFault = NSError(domain: "FIRFirestoreErrorDomain", code: 13)
        XCTAssertFalse(CrashlyticsErrorLogger.isReportable(permDenied))
        XCTAssertFalse(CrashlyticsErrorLogger.isReportable(unavailable))
        XCTAssertTrue(CrashlyticsErrorLogger.isReportable(internalFault))
    }
}
