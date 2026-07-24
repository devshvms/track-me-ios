import Foundation
import SwiftData

@MainActor
final class DataRepository {
    static let shared = DataRepository()
    var container: ModelContainer?

    // Location callbacks can arrive in batches. Keep their SwiftData work in
    // order so concurrent contexts cannot overwrite each other's relationship
    // updates, and so ride finalization can wait for the last point.
    private var pointWriteChain: Task<Void, Never>?

    func setup(container: ModelContainer) {
        self.container = container
    }

    func saveRide(_ ride: Ride) {
        guard let context = container?.mainContext else { return }
        context.insert(ride)
        try? context.save()
    }

    func allRides() -> [Ride] {
        guard let ctx = container?.mainContext else { return [] }
        return (try? ctx.fetch(FetchDescriptor<Ride>())) ?? []
    }

    /// Every identifier that already represents a locally-present cloud ride:
    /// firestoreId (once set on upload) + id.uuidString (covers legacy rides whose
    /// doc id equals their UUID but whose firestoreId was never set).
    func existingCloudIds() -> Set<String> {
        var ids = Set<String>()
        for r in allRides() {
            if let f = r.firestoreId { ids.insert(f) }
            ids.insert(r.id.uuidString)
        }
        return ids
    }

    func importDownloadedRides(_ downloaded: [DownloadedRide], existingIds: Set<String>) {
        guard let ctx = container?.mainContext else { return }
        var inserted = 0
        for d in downloaded {
            // Dedup: skip if the firestoreId OR the (iOS-origin) uuid is already local.
            if existingIds.contains(d.firestoreId) || existingIds.contains(d.localId.uuidString) { continue }
            let ride = Ride(id: d.localId, startTime: d.startTime,
                            sourceInfo: d.sourceInfo, isSynced: true, title: d.title)
            ride.endTime = d.endTime
            ride.firestoreId = d.firestoreId
            ctx.insert(ride)
            for p in d.points {
                let point = GPSPoint(latitude: p.latitude, longitude: p.longitude,
                                     altitude: p.altitude, accuracy: p.accuracy,
                                     speed: p.speed, timestamp: p.timestamp, isPaused: p.isPaused)
                point.ride = ride
                ctx.insert(point)
            }
            
            let pts = ride.points ?? []
            let distance = RideMetrics.rawDistanceMeters(pts)
            let durationMillis = Int((ride.endTime ?? Date()).timeIntervalSince(ride.startTime) * 1000)
            let maxSpeed = pts.map { $0.speed }.max() ?? 0.0
            let avgSpeed = durationMillis > 0 ? distance / (Double(durationMillis) / 1000.0) : 0.0
            
            ride.distanceMeters = distance
            ride.movingDurationMillis = durationMillis
            ride.pointCount = pts.count
            ride.maxSpeedMps = maxSpeed
            ride.avgSpeedMps = avgSpeed
            
            inserted += 1
        }
        if inserted > 0 { try? ctx.save() }
    }
    func savePointBackground(rideId: UUID, lat: Double, lng: Double, alt: Double, acc: Double, spd: Double, ts: Date, paused: Bool) {
        guard let container = container else { return }

        let previousWrite = pointWriteChain
        pointWriteChain = Task { [weak self] in
            await previousWrite?.value
            guard self != nil else { return }

            let context = ModelContext(container)
            // Fetch the ride using its id in the serialized write context.
            let descriptor = FetchDescriptor<Ride>(predicate: #Predicate { $0.id == rideId })
            do {
                guard let ride = try context.fetch(descriptor).first else { return }
                let point = GPSPoint(latitude: lat, longitude: lng, altitude: alt, accuracy: acc, speed: spd, timestamp: ts, isPaused: paused)
                ride.points?.append(point)
                context.insert(point)
                try context.save()
            } catch {
                if Self.isOutOfSpace(error) {
                    // Disk filled mid-write — park the ride instead of losing points silently.
                    TrackingManager.shared.enterStorageLowState()
                } else {
                    NSLog("TrackMe: failed to persist GPS point: %@", error.localizedDescription)
                }
            }
        }
    }

    /// Detects out-of-space failures (Cocoa `NSFileWriteOutOfSpaceError` or
    /// SQLite `SQLITE_FULL`), including when SwiftData wraps the underlying error.
    static func isOutOfSpace(_ error: Error) -> Bool {
        func matches(_ e: NSError) -> Bool {
            (e.domain == NSCocoaErrorDomain && e.code == NSFileWriteOutOfSpaceError)
                || (e.domain == "NSSQLiteErrorDomain" && e.code == 13) // SQLITE_FULL
        }
        let ns = error as NSError
        if matches(ns) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, matches(underlying) { return true }
        return false
    }

    func finishRide(rideId: UUID, distanceMeters: Double? = nil, movingDurationMillis: Int? = nil, maxSpeedMps: Double? = nil) {
        guard let container = container else { return }

        let pendingWrites = pointWriteChain
        pointWriteChain = Task { [weak self] in
            await pendingWrites?.value
            guard self != nil else { return }

            let context = ModelContext(container)
            let descriptor = FetchDescriptor<Ride>(predicate: #Predicate { $0.id == rideId })
            do {
                guard let ride = try context.fetch(descriptor).first else { return }
                ride.endTime = Date()

                if let d = distanceMeters { ride.distanceMeters = d }
                if let md = movingDurationMillis { ride.movingDurationMillis = md }
                if let ms = maxSpeedMps { ride.maxSpeedMps = ms }
                
                let pts = ride.points ?? []
                ride.pointCount = pts.count
                if let md = movingDurationMillis, md > 0, let d = distanceMeters {
                    ride.avgSpeedMps = d / (Double(md) / 1000.0)
                } else {
                    ride.avgSpeedMps = 0.0
                }

                if ride.title == nil || ride.title?.isEmpty == true {
                    ride.title = RideTitleGenerator.make(startTime: ride.startTime, points: pts)
                }

                try context.save()

                // Fire and forget cloud sync
                FirestoreSyncManager.shared.syncRide(ride)
            } catch {
                if Self.isOutOfSpace(error) {
                    ToastManager.shared.show(
                        message: LocalizationHelper.localized("Couldn't save ride — free up storage and try again."),
                        style: .error
                    )
                }
                NSLog("TrackMe: failed to finalize ride: %@", error.localizedDescription)
            }
        }
    }

    /// Deletes ALL locally-stored rides and GPS points. Serialized behind any pending
    /// point writes so a concurrent background insert can't resurrect a row after the wipe.
    /// Throws if the SwiftData delete/save fails (caller must NOT report success on throw).
    func wipeAllLocalData() async throws {
        guard let container = container else { return }

        // Drain any in-flight point writes first (same pattern as finishRide).
        let pending = pointWriteChain
        await pending?.value

        let context = ModelContext(container)
        // Delete points before rides to avoid dangling relationships regardless of the
        // container's delete rule. Bulk model-delete is available on this deployment target.
        try context.delete(model: GPSPoint.self)
        try context.delete(model: Ride.self)
        // TODO(prompt-16): also delete Emergency* models + stop active broadcast
        try context.save()
    }
}
