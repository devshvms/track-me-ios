import Foundation
import Observation
import SwiftData

nonisolated enum HomeDashboardIndexContract {
    static let singletonKey = "home-dashboard"
    // v2 changes the encoded weekly persona-distance payload from a positional number array to
    // typed persona/value facts. Reject v1 rather than assigning an old value by enum position.
    static let indexVersion = 2
    /// TASK-246 raised this from 1 so every existing ride is swept once and gains its stored
    /// route shape. Without the bump the reconcile predicate would never look at them again and
    /// the History cards would stay generic for all history recorded before this build.
    /// TASK-275 raised this to 3 so every existing ride is swept once and gains its content hash.
    /// The bump is the mechanism, not an accident of editing: `refreshDashboardMetadata` is what
    /// writes the hash, and the reconcile predicate only looks at rows *below* the current version.
    /// Left at 2, every ride that already existed would have kept a nil hash forever, and the
    /// re-import-your-own-export case would have stayed open for the users who have history.
    static let metadataVersion = 3
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
    ///
    /// - Parameter freshPoints: only for callers that have just built points and not yet saved,
    ///   where the `points` relationship may not have materialised. Everyone else omits it.
    func refreshDashboardMetadata(freshPoints: [GPSPoint]? = nil) {
        // TASK-246: the route shape is derived here from `self` rather than being a required
        // argument. Android's equivalent takes it as a parameter and four of its five call sites
        // quietly omitted it, which is why every cloud-synced ride there kept the generic glyph.
        // A Ride already owns its points, so deriving the shape removes the argument that could be
        // forgotten -- and this method has nine callers, every one of which was a chance to forget.
        //
        // `freshPoints` is the one exception, and it is the opposite of Android's mistake: it is
        // for a caller that has *more* truth than the relationship does, because it inserted the
        // points moments ago and has not saved yet.
        //
        // Set before the guard: a ride with an incomplete aggregate can still have a drawable
        // track, and the thumbnail is not gated on qualifying for stats.
        let trackPoints = freshPoints ?? points ?? []
        routePolyline = RoutePolyline.encoded(from: trackPoints)
        // TASK-275: derived here rather than passed in, for the same reason the polyline above is.
        // Android takes it as a required argument; this file already argues why that shape is a
        // trap with nine callers, and a Ride owns its points.
        contentHash = RideContentHash.of(trackPoints) ?? contentHash
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

    /// TASK-225: does a sample ride exist at all?
    ///
    /// Deliberately separate from `rebuildIndex`, whose predicate filters `!isSample` and must keep
    /// doing so — samples staying out of every aggregate is the whole reason the empty state exists.
    /// One bounded fetch, no route points.
    func hasSampleRide() throws -> Bool {
        var descriptor = FetchDescriptor<Ride>(
            predicate: #Predicate { $0.isSample && !$0.pendingDelete }
        )
        descriptor.fetchLimit = 1
        return try !modelContext.fetch(descriptor).isEmpty
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
                pointCount: max(0, pointCount),
                sourceRaw: ride.source
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
    /// TASK-225. A sibling fact, not an aggregate — it rides alongside the summary rather than
    /// inside it, because the summary is persisted as a Codable payload and this does not belong in
    /// that shape. Android attaches it to its summary for the same reason in reverse: there the
    /// summary is a live flow combine, not a stored blob.
    private(set) var hasSampleRide = false

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
            hasSampleRide = try await worker.hasSampleRide()
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
                let sampleExists = try await worker.hasSampleRide()
                guard generation == rebuildGeneration else { return }
                summary = rebuilt
                hasSampleRide = sampleExists
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
