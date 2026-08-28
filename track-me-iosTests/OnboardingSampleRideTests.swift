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

/// TASK-248. The sample is the first ride most riders open, and it was the one ride whose stat grid
/// had a hole in it: five populated cells beside a missing elevation, while Android additionally
/// printed "Unknown" for a duration its own average speed had been derived from.
@Suite
struct SampleRideMetadataTests {

    @Test
    func theSampleCarriesAnElevationFigureRatherThanAnEmptyCell() {
        let ride = OnboardingDemoFixture.makeRide()
        // §5.2 reserves the absent cell for altitude we never had. This track has an altitude on
        // every point and is genuinely flat, so 0 m is a measurement, not a guess.
        let elevation = ride.elevationGainMeters
        #expect(elevation != nil, "a flat track still has a known gain")
        #expect((elevation ?? 99) < 1.0, "flat terrain cannot climb")
    }

    @Test
    func theSampleDurationAgreesWithTheAverageSpeedBesideIt() {
        // §5.1's invariant, applied to the one ride that could not satisfy it: distance ÷ duration
        // must land on the speed the grid prints next to them.
        let ride = OnboardingDemoFixture.makeRide()
        guard let distance = ride.distanceMeters,
              let movingMillis = ride.movingDurationMillis, movingMillis > 0,
              let speed = ride.avgSpeedMps else {
            Issue.record("the sample must carry distance, duration and speed")
            return
        }
        let implied = distance / (Double(movingMillis) / 1_000)
        #expect(abs(implied - speed) <= speed * 0.05)
    }
}
