import Foundation
import Observation
import SwiftData

nonisolated enum HomeDashboardIndexContract {
    static let singletonKey = "home-dashboard"
    static let indexVersion = 1
    static let metadataVersion = 1
}

@Model
final class HomeDashboardIndex {
    @Attribute(.unique) var key: String = HomeDashboardIndexContract.singletonKey
    var schemaVersion: Int = 0
    var asOfEpochDay: Int = 0
    var lifetimeActivityCount: Int = 0
    var lifetimeDistanceMeters: Double = 0
    var lifetimeActiveDurationMillis: Int64 = 0
    var displayStreakWeeks: Int = 0
    var payload: Data = Data()

    init(
        key: String = HomeDashboardIndexContract.singletonKey,
        schemaVersion: Int,
        asOfEpochDay: Int,
        summary: HomeDashboardSummary,
        payload: Data
    ) {
        self.key = key
        self.schemaVersion = schemaVersion
        self.asOfEpochDay = asOfEpochDay
        self.lifetimeActivityCount = summary.lifetimeActivityCount
        self.lifetimeDistanceMeters = summary.lifetimeDistanceMeters
        self.lifetimeActiveDurationMillis = summary.lifetimeActiveDurationMillis
        self.displayStreakWeeks = summary.displayStreakWeeks
        self.payload = payload
    }

    func update(asOfEpochDay: Int, summary: HomeDashboardSummary, payload: Data) {
        schemaVersion = HomeDashboardIndexContract.indexVersion
        self.asOfEpochDay = asOfEpochDay
        lifetimeActivityCount = summary.lifetimeActivityCount
        lifetimeDistanceMeters = summary.lifetimeDistanceMeters
        lifetimeActiveDurationMillis = summary.lifetimeActiveDurationMillis
        displayStreakWeeks = summary.displayStreakWeeks
        self.payload = payload
    }
}

extension Ride {
    var hasCompleteDashboardMetadata: Bool {
        dashboardMetadataVersion == HomeDashboardIndexContract.metadataVersion
    }

    /// Applies the one canonical qualification rule after aggregate metadata exists.
    func refreshDashboardMetadata() {
        guard let endTime,
              endTime > startTime,
              let distanceMeters,
              let movingDurationMillis,
              maxSpeedMps != nil,
              avgSpeedMps != nil,
              pointCount != nil else {
            qualifiesForStats = false
            dashboardMetadataVersion = HomeDashboardIndexContract.metadataVersion
            return
        }
        let distance = RideMetrics.nonNegativeFinite(distanceMeters)
        let duration = max(0, movingDurationMillis)
        let junk = distance < 10 && duration < 120_000
        qualifiesForStats = !isSample && !pendingDelete && !junk
        dashboardMetadataVersion = HomeDashboardIndexContract.metadataVersion
    }
}

nonisolated struct HomeDashboardRoutePoint: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
}

@ModelActor
actor HomeDashboardWorker {
    func cachedSummary(now: Date, timeZoneIdentifier: String) throws -> HomeDashboardSummary? {
        let key = HomeDashboardIndexContract.singletonKey
        let descriptor = FetchDescriptor<HomeDashboardIndex>(
            predicate: #Predicate { $0.key == key }
        )
        guard let index = try modelContext.fetch(descriptor).first,
              index.schemaVersion == HomeDashboardIndexContract.indexVersion,
              index.asOfEpochDay == HomeCalendar.epochDay(
                  for: now,
                  timeZone: TimeZone(identifier: timeZoneIdentifier) ?? .current
              ) else { return nil }
        return try? JSONDecoder().decode(HomeDashboardSummary.self, from: index.payload)
    }

    /// Paged reconciliation keeps legacy point reads bounded and off the UI actor.
    @discardableResult
    func reconcileLegacyMetadata(pageSize: Int = 25) throws -> Int {
        precondition((1...100).contains(pageSize))
        let metadataVersion = HomeDashboardIndexContract.metadataVersion
        var reconciled = 0

        while true {
            var descriptor = FetchDescriptor<Ride>(
                predicate: #Predicate {
                    $0.endTime != nil && $0.dashboardMetadataVersion < metadataVersion
                },
                sortBy: [SortDescriptor(\Ride.startTime)]
            )
            descriptor.fetchLimit = pageSize
            let page = try modelContext.fetch(descriptor)
            guard !page.isEmpty else { break }

            for ride in page {
                if !ride.hasCompleteAggregate {
                    ride.applyAggregate(RideMetrics.reconstructed(from: ride.points ?? []))
                    ride.isSynced = false
                }
                ride.refreshDashboardMetadata()
                reconciled += 1
            }
            try modelContext.save()
        }
        return reconciled
    }

    func rebuildIndex(now: Date, timeZoneIdentifier: String) throws -> HomeDashboardSummary {
        let metadataVersion = HomeDashboardIndexContract.metadataVersion
        let descriptor = FetchDescriptor<Ride>(
            predicate: #Predicate {
                $0.endTime != nil
                    && $0.dashboardMetadataVersion == metadataVersion
                    && $0.qualifiesForStats
                    && !$0.pendingDelete
                    && !$0.isSample
            },
            sortBy: [SortDescriptor(\Ride.startTime, order: .reverse)]
        )
        let metadata = try modelContext.fetch(descriptor).compactMap { ride -> HomeDashboardRideMetadata? in
            guard let distance = ride.distanceMeters,
                  let duration = ride.movingDurationMillis,
                  let average = ride.avgSpeedMps,
                  let pointCount = ride.pointCount else { return nil }
            return HomeDashboardRideMetadata(
                localId: ride.id,
                persona: ride.ridePersona,
                startedAt: ride.startTime,
                startZoneId: ride.startZoneId,
                distanceMeters: RideMetrics.nonNegativeFinite(distance),
                activeDurationMillis: max(0, duration),
                avgSpeedMps: RideMetrics.nonNegativeFinite(average),
                pointCount: max(0, pointCount)
            )
        }
        let timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        let summary = HomeDashboardSelector.select(
            rides: metadata,
            now: now,
            fallbackTimeZone: timeZone
        )
        let payload = try JSONEncoder().encode(summary)
        let epochDay = HomeCalendar.epochDay(for: now, timeZone: timeZone)
        let key = HomeDashboardIndexContract.singletonKey
        let indexDescriptor = FetchDescriptor<HomeDashboardIndex>(
            predicate: #Predicate { $0.key == key }
        )
        if let index = try modelContext.fetch(indexDescriptor).first {
            index.update(asOfEpochDay: epochDay, summary: summary, payload: payload)
        } else {
            modelContext.insert(HomeDashboardIndex(
                schemaVersion: HomeDashboardIndexContract.indexVersion,
                asOfEpochDay: epochDay,
                summary: summary,
                payload: payload
            ))
        }
        try modelContext.save()
        return summary
    }

    func routePreview(rideId: UUID, limit: Int = 256) throws -> [HomeDashboardRoutePoint] {
        precondition(limit >= 2)
        var descriptor = FetchDescriptor<Ride>(predicate: #Predicate { $0.id == rideId })
        descriptor.fetchLimit = 1
        guard let ride = try modelContext.fetch(descriptor).first else { return [] }
        let points = (ride.points ?? []).sorted { $0.timestamp < $1.timestamp }.map {
            HomeDashboardRoutePoint(latitude: $0.latitude, longitude: $0.longitude)
        }
        return Self.downsample(points, limit: limit)
    }

    nonisolated static func downsample(
        _ points: [HomeDashboardRoutePoint],
        limit: Int
    ) -> [HomeDashboardRoutePoint] {
        guard points.count > limit else { return points }
        let interiorSlots = limit - 2
        let lastIndex = points.count - 1
        var result = [points[0]]
        result.reserveCapacity(limit)
        for slot in 1...interiorSlots {
            let index = slot * lastIndex / (limit - 1)
            result.append(points[index])
        }
        result.append(points[lastIndex])
        return result
    }
}

@MainActor
@Observable
final class HomeDashboardRepository {
    static let shared = HomeDashboardRepository()

    private(set) var summary: HomeDashboardSummary?
    private(set) var routePoints: [HomeDashboardRoutePoint] = []
    private(set) var isReconciling = true

    private var worker: HomeDashboardWorker?
    private var rebuildGeneration = 0
    private var routeGeneration = 0

    private init() {}

    func configure(container: ModelContainer) {
        guard worker == nil else { return }
        worker = HomeDashboardWorker(modelContainer: container)
    }

    func prepare() async {
        guard let worker else { return }
        let now = Date()
        let zone = TimeZone.current.identifier
        if let cached = try? await worker.cachedSummary(now: now, timeZoneIdentifier: zone) {
            summary = cached
        }
        do {
            try await worker.reconcileLegacyMetadata()
            summary = try await worker.rebuildIndex(now: Date(), timeZoneIdentifier: TimeZone.current.identifier)
        } catch {
            NSLog("TrackMe: Home dashboard preparation failed: %@", error.localizedDescription)
        }
        isReconciling = false
    }

    func invalidate() {
        guard let worker else { return }
        rebuildGeneration += 1
        let generation = rebuildGeneration
        Task {
            do {
                let rebuilt = try await worker.rebuildIndex(
                    now: Date(),
                    timeZoneIdentifier: TimeZone.current.identifier
                )
                guard generation == rebuildGeneration else { return }
                summary = rebuilt
            } catch {
                NSLog("TrackMe: Home dashboard index rebuild failed: %@", error.localizedDescription)
            }
        }
    }

    func refreshOnForeground() {
        invalidate()
    }

    func loadRoutePreview(for rideId: UUID?) {
        routeGeneration += 1
        let generation = routeGeneration
        routePoints = []
        guard let worker, let rideId else { return }
        Task {
            let points = (try? await worker.routePreview(rideId: rideId)) ?? []
            guard generation == routeGeneration else { return }
            routePoints = points
        }
    }

    func resetAfterWipe() {
        summary = .empty()
        routePoints = []
        isReconciling = false
        invalidate()
    }
}
