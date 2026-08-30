import Foundation
import SwiftData
import XCTest
@testable import track_me_ios

final class HomeDashboardPolicyTests: XCTestCase {
    func testDistanceByPersonaAggregation() {
        let now = date("2026-08-26T12:00:00Z")
        let summary = HomeDashboardSelector.select(
            rides: [
                metadata("2026-08-25T12:00:00Z", persona: .cycling, distance: 10000),
                metadata("2026-08-24T12:00:00Z", persona: .run, distance: 5000),
                metadata("2026-08-24T01:00:00Z", persona: .cycling, distance: 15000),
                metadata("2026-08-10T12:00:00Z", persona: .run, distance: 5000)
            ],
            now: now,
            fallbackTimeZone: TimeZone(identifier: "UTC")!
        )
        let week = summary.currentWeek
        XCTAssertEqual(week.activityCount, 3)
        XCTAssertEqual(week.distanceMeters, 30000)
        
        XCTAssertEqual(
            week.distanceByPersona.first { $0.persona == .cycling }?.distanceMeters,
            25_000
        )
        XCTAssertEqual(
            week.distanceByPersona.first { $0.persona == .run }?.distanceMeters,
            5_000
        )
    }

    func testZeroDistancePersonaRemainsAnExplicitWeeklyFact() {
        let summary = HomeDashboardSelector.select(
            rides: [metadata("2026-08-25T12:00:00Z", persona: .walk, distance: 0)],
            now: date("2026-08-26T12:00:00Z"),
            fallbackTimeZone: TimeZone(identifier: "UTC")!
        )

        XCTAssertEqual(summary.currentWeek.distanceByPersona, [
            HomePersonaDistance(persona: .walk, distanceMeters: 0)
        ])
    }

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

    func testSharedHomeVectorsFreezeWeeklyFactsAndExactComparisonPeriods() throws {
        let vectors = try sharedVectors()
        for vector in vectors.home_cases {
            let summary = HomeDashboardSelector.select(
                rides: vector.activities.map(vectorMetadata),
                now: Date(timeIntervalSince1970: Double(vector.now_epoch_millis) / 1_000),
                fallbackTimeZone: try XCTUnwrap(TimeZone(identifier: vector.fallback_timezone))
            )
            let expectedWeek = vector.expected_current_week
            XCTAssertEqual(summary.currentWeek.weekStartEpochDay, expectedWeek.week_start_epoch_day, vector.description)
            XCTAssertEqual(summary.currentWeek.activityCount, expectedWeek.activity_count, vector.description)
            XCTAssertEqual(summary.currentWeek.activeDurationMillis, expectedWeek.active_duration_millis, vector.description)
            XCTAssertEqual(
                summary.currentWeek.distanceByPersona,
                expectedWeek.distance_by_persona.map {
                    HomePersonaDistance(
                        persona: RidePersona(rawValue: $0.persona)!,
                        distanceMeters: $0.distance_meters
                    )
                },
                vector.description
            )

            if let expected = vector.expected_comparison {
                guard case let .periodComparison(
                    metric,
                    direction,
                    currentPeriod,
                    comparisonPeriod,
                    currentValue,
                    comparisonValue,
                    _
                ) = summary.insight else {
                    return XCTFail("Expected comparison: \(vector.description)")
                }
                XCTAssertEqual(metric.rawValue, expected.metric, vector.description)
                XCTAssertEqual(direction.rawValue, expected.direction, vector.description)
                XCTAssertEqual(currentPeriod.startEpochDay, expected.current_start_epoch_day, vector.description)
                XCTAssertEqual(currentPeriod.endEpochDay, expected.current_end_epoch_day, vector.description)
                XCTAssertEqual(comparisonPeriod.startEpochDay, expected.comparison_start_epoch_day, vector.description)
                XCTAssertEqual(comparisonPeriod.endEpochDay, expected.comparison_end_epoch_day, vector.description)
                XCTAssertEqual(currentValue, expected.current_value, accuracy: 0, vector.description)
                XCTAssertEqual(comparisonValue, expected.comparison_value, accuracy: 0, vector.description)
            } else if case .periodComparison = summary.insight {
                XCTFail("Unexpected comparison: \(vector.description)")
            }
        }
    }

    func testSharedCalendarVectorsFreezeMondayTimezoneAndDSTBucketing() throws {
        let vectors = try sharedVectors()
        for vector in vectors.calendar_cases {
            let summary = HomeDashboardSelector.select(
                rides: vector.activities.map(vectorMetadata),
                now: Date(timeIntervalSince1970: Double(vector.now_epoch_millis) / 1_000),
                fallbackTimeZone: try XCTUnwrap(TimeZone(identifier: vector.fallback_timezone))
            )
            XCTAssertEqual(
                summary.currentWeek.weekStartEpochDay,
                vector.expected_current_week_start_epoch_day,
                vector.description
            )
            XCTAssertEqual(
                summary.currentWeek.activityCount,
                vector.expected_current_week_activity_count,
                vector.description
            )
        }
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
            "Ride together", "View live map", "Return to Home dashboard",
            "Four-week duration: %@, %@, %@, and %@",
            "%@: %@ compared with %@",
            "Starter", "Moving", "Regular", "Explorer", "Enduring", "Pathfinder",
            "First Qualifying Activity", "%@ qualifying activities",
            "%@ active minutes • next level at %@", "Maximum level • %@ active minutes",
            "Unlocks at %@ active minutes", "My Progress", "View progress",
            "Levels", "Milestones", "Unlocked", "Locked", "Latest milestone"
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

    private func sharedVectors() throws -> GamificationVectors {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/home-gamification-v1.json")
        return try JSONDecoder().decode(GamificationVectors.self, from: Data(contentsOf: url))
    }

    private func vectorMetadata(_ vector: HomeActivityVector) -> HomeDashboardRideMetadata {
        let durationSeconds = Double(vector.active_duration_millis) / 1_000
        return HomeDashboardRideMetadata(
            localId: UUID(),
            persona: RidePersona(rawValue: vector.persona)!,
            startedAt: Date(timeIntervalSince1970: Double(vector.started_at_epoch_millis) / 1_000),
            startZoneId: vector.start_timezone,
            distanceMeters: vector.distance_meters,
            activeDurationMillis: vector.active_duration_millis,
            avgSpeedMps: durationSeconds > 0 ? vector.distance_meters / durationSeconds : 0,
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

    func testOldDashboardPayloadVersionFailsClosedForRebuild() async throws {
        let container = try ModelContainer(
            for: Ride.self,
            GPSPoint.self,
            HomeDashboardIndex.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let now = Date(timeIntervalSince1970: 1_777_200_000)
        let summary = HomeDashboardSummary.empty(now: now, timeZone: TimeZone(identifier: "UTC")!)
        let epochDay = HomeCalendar.epochDay(for: now, timeZone: TimeZone(identifier: "UTC")!)
        container.mainContext.insert(HomeDashboardIndex(
            schemaVersion: HomeDashboardIndexContract.indexVersion - 1,
            asOfEpochDay: epochDay,
            summary: summary,
            payload: try JSONEncoder().encode(summary)
        ))
        try container.mainContext.save()

        let worker = HomeDashboardWorker(modelContainer: container)
        let cached = try await worker.cachedSummary(now: now, timeZoneIdentifier: "UTC")

        XCTAssertNil(cached, "Old positional persona-distance payload must be rebuilt")
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
