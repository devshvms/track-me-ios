import Foundation

enum OnboardingState: String, Equatable {
    case pending
    case done
    case legacy
}

struct OnboardingOutcome {
    let attempts: Int
    let furthestPage: Int
    let usedSkip: Bool
    let seconds: Int
    let analyticsOptIn: Bool
    let locationGranted: Bool
    let notificationsGranted: Bool

    var telemetryProperties: [String: Any] {
        [
            "attempts": attempts,
            "furthest_page": furthestPage,
            "used_skip": usedSkip,
            "seconds": seconds,
            "analytics_opt_in": analyticsOptIn,
            "location_granted": locationGranted,
            "notifications_granted": notificationsGranted
        ]
    }
}

@MainActor
protocol OnboardingTelemetryClient {
    func updateLocalConsent(_ enabled: Bool)
    func trackOnboardingCompleted(_ outcome: OnboardingOutcome)
}

extension TelemetryManager: OnboardingTelemetryClient {}

enum OnboardingGate {
    static let stateKey = "onboarding.state"
    static let attemptsKey = "onboarding.attempts"
    static let lastVersionKey = "onboarding.lastLaunchedVersion"
    static let startHintSeenKey = "onboarding.legacyStartHintSeen"

    static func resolve(
        stored: String?,
        hasExistingPreferences: Bool,
        wasUpdated: Bool
    ) -> OnboardingState {
        if let stored, let state = OnboardingState(rawValue: stored) {
            return state
        }
        return hasExistingPreferences || wasUpdated ? .legacy : .pending
    }

    @discardableResult
    static func resolveAtLaunch(
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main
    ) -> OnboardingState {
        let currentVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let previousVersion = defaults.string(forKey: lastVersionKey)
        let persisted = bundle.bundleIdentifier
            .flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        let gateKeys = Set([stateKey, attemptsKey, lastVersionKey, startHintSeenKey])
        let hasExistingPreferences = persisted.keys.contains { !gateKeys.contains($0) }
        let wasUpdated = previousVersion.map { $0 != currentVersion } ?? false
        let state = resolve(
            stored: defaults.string(forKey: stateKey),
            hasExistingPreferences: hasExistingPreferences,
            wasUpdated: wasUpdated
        )

        defaults.set(state.rawValue, forKey: stateKey)
        defaults.set(currentVersion, forKey: lastVersionKey)
        return state
    }

    static func recordAttempt(defaults: UserDefaults = .standard) -> Int {
        let attempts = defaults.integer(forKey: attemptsKey) + 1
        defaults.set(attempts, forKey: attemptsKey)
        return attempts
    }

    @MainActor
    static func complete(
        _ outcome: OnboardingOutcome,
        defaults: UserDefaults = .standard
    ) {
        complete(outcome, defaults: defaults, telemetry: TelemetryManager.shared)
    }

    @MainActor
    static func complete(
        _ outcome: OnboardingOutcome,
        defaults: UserDefaults,
        telemetry: OnboardingTelemetryClient
    ) {
        defaults.set(outcome.analyticsOptIn, forKey: "enableTelemetry")
        telemetry.updateLocalConsent(outcome.analyticsOptIn)
        telemetry.trackOnboardingCompleted(outcome)
        defaults.set(OnboardingState.done.rawValue, forKey: stateKey)
    }

    static func shouldShowStartRideHint(state: OnboardingState, hintAlreadySeen: Bool) -> Bool {
        state == .legacy && !hintAlreadySeen
    }
}

enum AnalyticsDefault {
    static let onEverywhere = false

    private static let consentRequired: Set<String> = [
        "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR", "DE", "GR", "HU", "IE",
        "IT", "LV", "LT", "LU", "MT", "NL", "PL", "PT", "RO", "SK", "SI", "ES", "SE",
        "IS", "LI", "NO", "GB", "CH"
    ]

    static func startsOn(primaryCountryCode: String?, localeCountryCode: String?) -> Bool {
        if onEverywhere { return true }
        let country = normalized(primaryCountryCode) ?? normalized(localeCountryCode)
        guard let country else { return false }
        return !consentRequired.contains(country)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return normalized.isEmpty ? nil : normalized
    }
}
