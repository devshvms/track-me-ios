import Foundation
import SwiftData
import XCTest
@testable import track_me_ios

final class HomeDashboardPolicyTests: XCTestCase {
    func testPresentationModePrecedenceKeepsActiveTrackingAboveGroupMap() {
        XCTAssertEqual(
            HomePresentationModePolicy.resolve(isTrackingIdle: false, explicitGroupMap: true),
            .activeTrackingMap
        )
        XCTAssertEqual(
            HomePresentationModePolicy.resolve(isTrackingIdle: true, explicitGroupMap: true),
            .explicitGroupMap
        )
        XCTAssertEqual(
            HomePresentationModePolicy.resolve(isTrackingIdle: true, explicitGroupMap: false),
            .idleDashboard
        )
    }

    func testCurrentAndPreviousWeekContinueStreakButOlderHistoryDoesNot() {
        let zone = TimeZone(identifier: "Asia/Kolkata")!
        let now = date("2026-08-26T12:00:00Z")
        let current = HomeDashboardSelector.select(
            rides: [
                metadata("2026-08-25T03:00:00Z"),
                metadata("2026-08-18T03:00:00Z"),
                metadata("2026-08-11T03:00:00Z")
            ],
            now: now,
            fallbackTimeZone: zone
        )
        XCTAssertEqual(current.displayStreakWeeks, 3)

        let previous = HomeDashboardSelector.select(
            rides: [
                metadata("2026-08-18T03:00:00Z"),
                metadata("2026-08-11T03:00:00Z")
            ],
            now: now,
            fallbackTimeZone: zone
        )
        XCTAssertEqual(previous.displayStreakWeeks, 2)

        let stale = HomeDashboardSelector.select(
            rides: [metadata("2026-08-11T03:00:00Z")],
            now: now,
            fallbackTimeZone: zone
        )
        XCTAssertEqual(stale.displayStreakWeeks, 0)
    }

    func testRecordedStartTimezoneControlsMondayBucket() {
        let now = date("2026-08-24T00:05:00Z")
        let started = "2026-08-23T23:55:00Z"
        let india = HomeDashboardSelector.select(
            rides: [metadata(started, startZoneId: "Asia/Kolkata")],
            now: now,
            fallbackTimeZone: TimeZone(secondsFromGMT: 0)!
        )
        let utc = HomeDashboardSelector.select(
            rides: [metadata(started, startZoneId: "UTC")],
            now: now,
            fallbackTimeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertNotEqual(india.currentWeek.activityCount, utc.currentWeek.activityCount)
        XCTAssertEqual(india.currentWeek.activityCount, 1)
        XCTAssertEqual(utc.currentWeek.activityCount, 0)
    }

    func testReturnInsightHasPriorityOverComparisonAndDominantPersona() {
        let result = HomeDashboardSelector.select(
            rides: [
                metadata("2026-08-25T06:00:00Z", persona: .run, distance: 3_000),
                metadata("2026-08-01T06:00:00Z", persona: .run, distance: 2_000),
                metadata("2026-07-31T06:00:00Z", persona: .run, distance: 2_000)
            ],
            now: date("2026-08-26T12:00:00Z"),
            fallbackTimeZone: TimeZone(identifier: "UTC")!
        )
        guard case let .returning(persona, inactiveDays) = result.insight else {
            return XCTFail("Expected return insight")
        }
        XCTAssertEqual(persona, .run)
        XCTAssertEqual(inactiveDays, 24)
    }

    func testComparisonUsesTenPercentStableDeadbandAndRejectsZeroDenominator() {
        let stable = HomeDashboardSelector.select(
            rides: [
                metadata("2026-08-25T06:00:00Z", distance: 950),
                metadata("2026-08-18T06:00:00Z", distance: 500),
                metadata("2026-08-17T06:00:00Z", distance: 500)
            ],
            now: date("2026-08-26T12:00:00Z"),
            fallbackTimeZone: TimeZone(identifier: "UTC")!
        )
        guard case let .periodComparison(_, direction, _, _, _, _, delta) = stable.insight else {
            return XCTFail("Expected comparison insight")
        }
        XCTAssertEqual(direction, .stable)
        XCTAssertEqual(delta, -5, accuracy: 0.001)

        let zero = HomeDashboardSelector.select(
            rides: [
                metadata("2026-08-25T06:00:00Z", persona: .run, distance: 500),
                metadata("2026-08-18T06:00:00Z", persona: .run, distance: 0),
                metadata("2026-08-17T06:00:00Z", persona: .run, distance: 0)
            ],
            now: date("2026-08-26T12:00:00Z"),
            fallbackTimeZone: TimeZone(identifier: "UTC")!
        )
        guard case .dominantPersona = zero.insight else {
            return XCTFail("Zero denominator must fall through to the next eligible insight")
        }
    }

    func testDominantPersonaRequiresUniqueLeader() {
        let now = date("2026-08-26T12:00:00Z")
        let dominant = HomeDashboardSelector.select(
            rides: [
                metadata("2026-08-19T06:00:00Z", persona: .cycling),
                metadata("2026-08-18T06:00:00Z", persona: .cycling),
                metadata("2026-08-17T06:00:00Z", persona: .run)
            ],
            now: now,
            fallbackTimeZone: TimeZone(identifier: "UTC")!
        )
        guard case let .dominantPersona(persona, count, total, _, _) = dominant.insight else {
            return XCTFail("Expected dominant persona")
        }
        XCTAssertEqual(persona, .cycling)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(total, 3)
    }

    func testSelectorHandlesLargeMetadataOnlyHistory() {
        let now = date("2026-08-26T12:00:00Z")
        let rides = (0..<600).map { index in
            HomeDashboardRideMetadata(
                localId: UUID(),
                persona: index.isMultiple(of: 2) ? .cycling : .run,
                startedAt: now.addingTimeInterval(TimeInterval(-index * 86_400)),
                startZoneId: "UTC",
                distanceMeters: 1_000,
                activeDurationMillis: 300_000,
                avgSpeedMps: 3.33,
                pointCount: 20_000
            )
        }
        let summary = HomeDashboardSelector.select(
            rides: rides,
            now: now,
            fallbackTimeZone: TimeZone(identifier: "UTC")!
        )
        XCTAssertEqual(summary.lifetimeActivityCount, 600)
        XCTAssertEqual(summary.lifetimeDistanceMeters, 600_000)
        XCTAssertEqual(summary.weeklyBuckets.count, 8)
    }

    func testRouteDownsampleRetainsEndpointsAndLimit() {
        let points = (0..<1_001).map {
            HomeDashboardRoutePoint(latitude: Double($0), longitude: Double(-$0))
        }
        let result = HomeDashboardWorker.downsample(points, limit: 256)
        XCTAssertEqual(result.count, 256)
        XCTAssertEqual(result.first, points.first)
        XCTAssertEqual(result.last, points.last)
    }

    func testPersonaPreferenceOnlyChangesWhenCommittedStartIsRecorded() {
        let suiteName = "HomeDashboardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        DashboardPersonaPreference.recordOnboardingFallback(.walk, defaults: defaults)
        XCTAssertEqual(DashboardPersonaPreference.selected(defaults: defaults), .walk)

        // Merely selecting a persona is transient; only a committed recording calls this writer.
        XCTAssertEqual(DashboardPersonaPreference.selected(defaults: defaults), .walk)
        DashboardPersonaPreference.recordCommittedStart(.cycling, defaults: defaults)
        XCTAssertEqual(DashboardPersonaPreference.selected(defaults: defaults), .cycling)
    }

    func testTelemetryUsesClosedNonPIIVocabulary() throws {
        let event = try XCTUnwrap(HomeTelemetryContract.insightShown(.dominantPersona(
            persona: .run,
            personaCount: 3,
            totalCount: 4,
            windowStartEpochDay: 10,
            windowEndEpochDay: 20
        )))
        XCTAssertEqual(event.name, "home_insight_shown")
        XCTAssertEqual(event.properties, ["insight_type": "dominant_persona"])
        XCTAssertFalse(HomeTelemetryContract.allowedInsightTypes.contains("personal_best"))
        XCTAssertTrue(Set(event.properties.keys).isDisjoint(with: HomeTelemetryContract.privacyForbiddenKeys))
    }

    func testDashboardCopyIsLocalizedInEveryShippedTranslation() throws {
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("track-me-ios/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        let keys = [
            "Start %@", "This week", "Insights", "Recent activity",
            "Private by default • Works offline", "Group session active",
            "Open Community", "View live map", "Return to Home dashboard"
        ]
        for key in keys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            for locale in ["de", "es", "fr", "hi", "ja", "zh-Hans"] {
                XCTAssertNotNil(localizations[locale], "Missing \(locale) for \(key)")
            }
        }
    }

    private func metadata(
        _ isoDate: String,
        persona: RidePersona = .cycling,
        startZoneId: String? = "UTC",
        distance: Double = 1_000
    ) -> HomeDashboardRideMetadata {
        HomeDashboardRideMetadata(
            localId: UUID(),
            persona: persona,
            startedAt: date(isoDate),
            startZoneId: startZoneId,
            distanceMeters: distance,
            activeDurationMillis: 300_000,
            avgSpeedMps: distance / 300,
            pointCount: 100
        )
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

}

@MainActor
final class HomeDashboardPersistenceTests: XCTestCase {
    func testQualificationRejectsSampleAndNearEmptyRows() {
        let junk = completeRide(distance: 9, duration: 119_000)
        junk.refreshDashboardMetadata()
        XCTAssertFalse(junk.qualifiesForStats)

        let valid = completeRide(distance: 10, duration: 120_000)
        valid.refreshDashboardMetadata()
        XCTAssertTrue(valid.qualifiesForStats)

        let sample = completeRide(distance: 1_000, duration: 300_000)
        sample.isSample = true
        sample.refreshDashboardMetadata()
        XCTAssertFalse(sample.qualifiesForStats)
    }

    func testWorkerPersistsRebuildableSingletonIndex() async throws {
        let container = try ModelContainer(
            for: Ride.self,
            GPSPoint.self,
            HomeDashboardIndex.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        for daysAgo in 0..<3 {
            let ride = completeRide(distance: Double(daysAgo + 1) * 1_000, duration: 300_000)
            ride.startTime = Date(timeIntervalSince1970: 1_777_200_000 - Double(daysAgo * 86_400))
            ride.endTime = ride.startTime.addingTimeInterval(600)
            ride.startZoneId = "UTC"
            container.mainContext.insert(ride)
        }
        try container.mainContext.save()

        let worker = HomeDashboardWorker(modelContainer: container)
        let reconciled = try await worker.reconcileLegacyMetadata(pageSize: 2)
        XCTAssertEqual(reconciled, 3)
        let now = Date(timeIntervalSince1970: 1_777_200_000)
        let summary = try await worker.rebuildIndex(now: now, timeZoneIdentifier: "UTC")
        XCTAssertEqual(summary.lifetimeActivityCount, 3)
        XCTAssertEqual(summary.lifetimeDistanceMeters, 6_000)

        let cached = try await worker.cachedSummary(now: now, timeZoneIdentifier: "UTC")
        XCTAssertEqual(cached, summary)
        let indexes = try container.mainContext.fetch(FetchDescriptor<HomeDashboardIndex>())
        XCTAssertEqual(indexes.count, 1)
        XCTAssertEqual(indexes.first?.lifetimeActivityCount, 3)
    }

    private func completeRide(distance: Double, duration: Int64) -> Ride {
        let ride = Ride(startTime: Date(timeIntervalSince1970: 1_777_200_000))
        ride.endTime = ride.startTime.addingTimeInterval(600)
        ride.distanceMeters = distance
        ride.movingDurationMillis = duration
        ride.maxSpeedMps = 8
        ride.avgSpeedMps = duration > 0 ? distance / (Double(duration) / 1_000) : 0
        ride.pointCount = 100
        return ride
    }
}
