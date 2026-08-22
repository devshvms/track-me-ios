import Foundation
import SwiftData

/// Durable first-run state. `.seeded` remains terminal after the sample is deleted.
nonisolated enum OnboardingSampleSeedState: String, Equatable {
    case eligible
    case pending
    case seeded
    case ineligible
}

nonisolated enum OnboardingSampleSeedPolicy {
    static func initialState(
        onboardingState: OnboardingState,
        wasUpdated: Bool
    ) -> OnboardingSampleSeedState {
        if wasUpdated { return .ineligible }
        return onboardingState == .pending ? .eligible : .ineligible
    }

    static func requestedState(_ current: OnboardingSampleSeedState) -> OnboardingSampleSeedState {
        current == .eligible ? .pending : current
    }

    static func shouldAttempt(
        state: OnboardingSampleSeedState,
        onboardingState: OnboardingState
    ) -> Bool {
        state == .pending && onboardingState == .done
    }
}

///
/// Seeds the canonical sample only for a genuinely fresh install after onboarding completes.
///
/// The state lives outside SwiftData so deleting the sample can never make it eligible again. The
/// model query independently closes the insert→defaults-write crash window without treating a
/// localized title or date as identity.
enum OnboardingSampleRideSeeder {
    static let stateKey = "onboarding.sampleRideSeedState"

    @discardableResult
    static func initialize(
        defaults: UserDefaults = .standard,
        onboardingState: OnboardingState,
        wasUpdated: Bool
    ) -> OnboardingSampleSeedState {
        if let raw = defaults.string(forKey: stateKey),
           let state = OnboardingSampleSeedState(rawValue: raw) {
            return state
        }
        let initial = OnboardingSampleSeedPolicy.initialState(
            onboardingState: onboardingState,
            wasUpdated: wasUpdated
        )
        defaults.set(initial.rawValue, forKey: stateKey)
        return initial
    }

    @discardableResult
    static func request(defaults: UserDefaults = .standard) -> Bool {
        guard let raw = defaults.string(forKey: stateKey),
              let current = OnboardingSampleSeedState(rawValue: raw) else { return false }
        let requested = OnboardingSampleSeedPolicy.requestedState(current)
        guard requested != current else { return false }
        defaults.set(requested.rawValue, forKey: stateKey)
        return true
    }

    @discardableResult
    @MainActor
    static func seedIfNeeded(
        context: ModelContext,
        defaults: UserDefaults = .standard,
        onboardingState: OnboardingState,
        title: String,
        now: Date = Date()
    ) throws -> Bool {
        guard let raw = defaults.string(forKey: stateKey),
              let state = OnboardingSampleSeedState(rawValue: raw),
              OnboardingSampleSeedPolicy.shouldAttempt(
                state: state,
                onboardingState: onboardingState
              ) else { return false }

        var descriptor = FetchDescriptor<Ride>(predicate: #Predicate { $0.isSample })
        descriptor.fetchLimit = 1
        if try context.fetch(descriptor).isEmpty {
            let ride = OnboardingDemoFixture.makeRide(
                startTime: now.addingTimeInterval(-OnboardingDemoFixture.duration),
                title: title
            )
            ride.isSample = true
            context.insert(ride)
            try context.save()
        }

        defaults.set(OnboardingSampleSeedState.seeded.rawValue, forKey: stateKey)
        return true
    }
}
