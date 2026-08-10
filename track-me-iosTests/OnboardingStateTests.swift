import XCTest
@testable import track_me_ios

final class OnboardingStateTests: XCTestCase {
    func testFreshInstallIsPending() {
        XCTAssertEqual(
            OnboardingGate.resolve(stored: nil, hasExistingPreferences: false, wasUpdated: false),
            .pending
        )
    }

    func testExistingPreferencesOrUpdateClassifiesAsLegacy() {
        XCTAssertEqual(
            OnboardingGate.resolve(stored: nil, hasExistingPreferences: true, wasUpdated: false),
            .legacy
        )
        XCTAssertEqual(
            OnboardingGate.resolve(stored: nil, hasExistingPreferences: false, wasUpdated: true),
            .legacy
        )
    }

    func testStoredStateAlwaysWins() {
        XCTAssertEqual(
            OnboardingGate.resolve(stored: "done", hasExistingPreferences: true, wasUpdated: true),
            .done
        )
        XCTAssertEqual(
            OnboardingGate.resolve(stored: "pending", hasExistingPreferences: true, wasUpdated: true),
            .pending
        )
    }

    func testOnlyLegacyUsersSeeTheOldStartHint() {
        XCTAssertTrue(OnboardingGate.shouldShowStartRideHint(state: .legacy, hintAlreadySeen: false))
        XCTAssertFalse(OnboardingGate.shouldShowStartRideHint(state: .legacy, hintAlreadySeen: true))
        XCTAssertFalse(OnboardingGate.shouldShowStartRideHint(state: .pending, hintAlreadySeen: false))
        XCTAssertFalse(OnboardingGate.shouldShowStartRideHint(state: .done, hintAlreadySeen: false))
    }

    func testAttemptCounterPersistsLocally() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        XCTAssertEqual(OnboardingGate.recordAttempt(defaults: defaults), 1)
        XCTAssertEqual(OnboardingGate.recordAttempt(defaults: defaults), 2)
    }
}

final class AnalyticsDefaultTests: XCTestCase {
    func testConsentRequiredRegionsStartOff() {
        XCTAssertFalse(AnalyticsDefault.startsOn(primaryCountryCode: "DE", localeCountryCode: "US"))
        XCTAssertFalse(AnalyticsDefault.startsOn(primaryCountryCode: "gb", localeCountryCode: "US"))
        XCTAssertFalse(AnalyticsDefault.startsOn(primaryCountryCode: "CH", localeCountryCode: "US"))
    }

    func testPrimaryRegionWinsAndOtherRegionsStartOn() {
        XCTAssertTrue(AnalyticsDefault.startsOn(primaryCountryCode: "US", localeCountryCode: "DE"))
        XCTAssertTrue(AnalyticsDefault.startsOn(primaryCountryCode: nil, localeCountryCode: "IN"))
    }

    func testUnknownRegionTakesCautiousBranch() {
        XCTAssertFalse(AnalyticsDefault.startsOn(primaryCountryCode: nil, localeCountryCode: nil))
        XCTAssertFalse(AnalyticsDefault.startsOn(primaryCountryCode: " ", localeCountryCode: ""))
    }
}

@MainActor
final class OnboardingCompletionTests: XCTestCase {
    func testConsentIsAppliedBeforeCompletionEvent() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let telemetry = TelemetrySpy(defaults: defaults)
        let outcome = OnboardingOutcome(
            attempts: 2,
            furthestPage: 5,
            usedSkip: true,
            seconds: 31,
            analyticsOptIn: true,
            locationGranted: true,
            notificationsGranted: false
        )

        OnboardingGate.complete(outcome, defaults: defaults, telemetry: telemetry)

        XCTAssertEqual(telemetry.calls, ["consent:true", "capture:true"])
        XCTAssertEqual(defaults.string(forKey: OnboardingGate.stateKey), OnboardingState.done.rawValue)
        XCTAssertEqual(outcome.telemetryProperties["attempts"] as? Int, 2)
        XCTAssertEqual(outcome.telemetryProperties["analytics_opt_in"] as? Bool, true)
    }
}

@MainActor
private final class TelemetrySpy: OnboardingTelemetryClient {
    private let defaults: UserDefaults
    var calls: [String] = []

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func updateLocalConsent(_ enabled: Bool) {
        calls.append("consent:\(defaults.bool(forKey: "enableTelemetry"))")
    }

    func trackOnboardingCompleted(_ outcome: OnboardingOutcome) {
        calls.append("capture:\(defaults.bool(forKey: "enableTelemetry"))")
    }
}
