import Foundation
import SwiftData
import Testing
@testable import track_me_ios

@Suite(.serialized)
struct OnboardingSampleRideTests {
    @Test
    func policyDistinguishesFreshInstallUpgradeAndTerminalDeletion() {
        #expect(OnboardingSampleSeedPolicy.initialState(
            onboardingState: .pending,
            wasUpdated: false
        ) == .eligible)
        #expect(OnboardingSampleSeedPolicy.initialState(
            onboardingState: .pending,
            wasUpdated: true
        ) == .ineligible)
        #expect(OnboardingSampleSeedPolicy.requestedState(.eligible) == .pending)
        #expect(OnboardingSampleSeedPolicy.requestedState(.seeded) == .seeded)
        #expect(OnboardingSampleSeedPolicy.shouldAttempt(
            state: .pending,
            onboardingState: .done
        ))
        #expect(!OnboardingSampleSeedPolicy.shouldAttempt(
            state: .seeded,
            onboardingState: .done
        ))
    }

    @MainActor
    @Test
    func seedingIsExactlyOnceAndDeletionIsPermanent() throws {
        let defaults = UserDefaults(suiteName: "OnboardingSampleRideTests.\(UUID().uuidString)")!
        defer {
            defaults.dictionaryRepresentation().keys.forEach {
                defaults.removeObject(forKey: $0)
            }
        }
        let container = try ModelContainer(
            for: Ride.self,
            GPSPoint.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext

        OnboardingSampleRideSeeder.initialize(
            defaults: defaults,
            onboardingState: .pending,
            wasUpdated: false
        )
        #expect(OnboardingSampleRideSeeder.request(defaults: defaults))

        #expect(try OnboardingSampleRideSeeder.seedIfNeeded(
            context: context,
            defaults: defaults,
            onboardingState: .done,
            title: "Sample ride"
        ))
        #expect(!(try OnboardingSampleRideSeeder.seedIfNeeded(
            context: context,
            defaults: defaults,
            onboardingState: .done,
            title: "Sample ride"
        )))

        var samples = try context.fetch(FetchDescriptor<Ride>(predicate: #Predicate { $0.isSample }))
        #expect(samples.count == 1)
        #expect(samples[0].points?.count == OnboardingDemoFixture.pointCount)
        #expect(samples[0].isSynced == false)

        context.delete(samples[0])
        try context.save()
        #expect(!(try OnboardingSampleRideSeeder.seedIfNeeded(
            context: context,
            defaults: defaults,
            onboardingState: .done,
            title: "Sample ride"
        )))
        samples = try context.fetch(FetchDescriptor<Ride>(predicate: #Predicate { $0.isSample }))
        #expect(samples.isEmpty)
    }

    @Test
    func sampleRideIsNeverCloudEligible() {
        #expect(FirestoreSyncManager.isRideEligibleForCloudSync(
            isSample: false,
            pendingDelete: false
        ))
        #expect(!FirestoreSyncManager.isRideEligibleForCloudSync(
            isSample: true,
            pendingDelete: false
        ))
        #expect(!FirestoreSyncManager.isRideEligibleForCloudSync(
            isSample: false,
            pendingDelete: true
        ))
    }

    @Test
    func sampleBadgeIsLocalizedInEveryNonEnglishCatalog() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("track-me-ios/Localizable.xcstrings")
        let data = try Data(contentsOf: source)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        let entry = try #require(strings["Sample"] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: Any])
        for locale in ["de", "es", "fr", "hi", "ja", "zh-Hans"] {
            #expect(localizations[locale] != nil)
        }
    }
}
