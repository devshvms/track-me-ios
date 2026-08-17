import Foundation
import SwiftData

@MainActor
final class DataRepository {
    static let shared = DataRepository()
    private static let personaTitleMigrationKey = "ride_persona_title_migration_v1"
    var container: ModelContainer?

    // Location callbacks can arrive in batches. Keep their SwiftData work in
    // order so concurrent contexts cannot overwrite each other's relationship
    // updates, and so ride finalization can wait for the last point.
    private var pointWriteChain: Task<Void, Never>?

    func setup(container: ModelContainer) {
        self.container = container
        migrateGeneratedPersonaTitlesIfNeeded()
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
            ride.persona = d.persona
            if ride.ridePersona != .auto, RideTitleGenerator.isGeneratedTitle(ride.title) {
                ride.title = RideTitleGenerator.make(
                    startTime: ride.startTime,
                    persona: ride.ridePersona,
                    maxSpeedKmh: nil
                )
                ride.isSynced = false
            }
            ride.firestoreId = d.firestoreId
            ride.cloudChunkCount = d.chunkCount
            ctx.insert(ride)
            var importedPoints: [GPSPoint] = []
            for p in d.points {
                let point = GPSPoint(latitude: p.latitude, longitude: p.longitude,
                                     altitude: p.altitude, accuracy: p.accuracy,
                                     speed: p.speed, timestamp: p.timestamp, isPaused: p.isPaused)
                point.ride = ride
                ctx.insert(point)
                importedPoints.append(point)
            }
            ride.applyAggregate(
                d.persistedAggregate
                    ?? d.aggregate(fallback: RideMetrics.reconstructed(from: importedPoints))
            )
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

    func finishRide(rideId: UUID, endedAt: Date, aggregate: RideAggregateSnapshot) {
        guard let container = container else { return }

        let pendingWrites = pointWriteChain
        pointWriteChain = Task { [weak self] in
            await pendingWrites?.value
            guard self != nil else { return }

            let context = ModelContext(container)
            let descriptor = FetchDescriptor<Ride>(predicate: #Predicate { $0.id == rideId })
            do {
                guard let ride = try context.fetch(descriptor).first else { return }
                ride.endTime = max(endedAt, ride.startTime)
                ride.applyAggregate(aggregate)

                if RideTitleGenerator.isGeneratedTitle(ride.title) {
                    ride.title = RideTitleGenerator.make(
                        startTime: ride.startTime,
                        persona: ride.ridePersona,
                        maxSpeedKmh: aggregate.maxSpeedMps * 3.6
                    )
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

    /// Removes a ride that was explicitly abandoned during the near-empty start window.
    /// Serialized behind point writes so an in-flight location callback cannot resurrect it.
    func deleteRide(rideId: UUID) {
        guard let container = container else { return }

        let pendingWrites = pointWriteChain
        pointWriteChain = Task { [weak self] in
            await pendingWrites?.value
            guard self != nil else { return }

            let context = ModelContext(container)
            let descriptor = FetchDescriptor<Ride>(predicate: #Predicate { $0.id == rideId })
            do {
                guard let ride = try context.fetch(descriptor).first else { return }
                context.delete(ride)
                try context.save()
            } catch {
                NSLog("TrackMe: failed to discard near-empty ride: %@", error.localizedDescription)
            }
        }
    }

    /// Marks a ride before any remote delete is attempted. The flag survives a
    /// process death and blocks upload, closing the resurrection window described
    /// in scope 1.7.3 §2 (pendingDelete → cloud batch → local delete).
    func markRidePendingDelete(rideId: UUID) -> Bool {
        guard let context = container?.mainContext else { return false }
        let descriptor = FetchDescriptor<Ride>(predicate: #Predicate { $0.id == rideId })
        guard let ride = try? context.fetch(descriptor).first else { return false }
        ride.pendingDelete = true
        do {
            try context.save()
            return true
        } catch {
            context.rollback()
            NSLog("TrackMe: failed to mark ride pending delete: %@", error.localizedDescription)
            return false
        }
    }

    func restorePendingDelete(rideId: UUID) {
        guard let context = container?.mainContext else { return }
        let descriptor = FetchDescriptor<Ride>(predicate: #Predicate { $0.id == rideId })
        guard let ride = try? context.fetch(descriptor).first else { return }
        ride.pendingDelete = false
        do {
            try context.save()
        } catch {
            context.rollback()
            NSLog("TrackMe: failed to restore ride after rejected delete: %@", error.localizedDescription)
        }
    }

    func pendingDeleteRides() -> [Ride] {
        allRides().filter(\.pendingDelete)
    }

    /// Corrects titles created before persona-aware naming landed. Only known
    /// generated titles are changed; a title edited by the user is never touched.
    private func migrateGeneratedPersonaTitlesIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.personaTitleMigrationKey),
              let context = container?.mainContext else { return }

        let rides = (try? context.fetch(FetchDescriptor<Ride>())) ?? []
        var changed = false
        for ride in rides where ride.ridePersona != .auto && RideTitleGenerator.isGeneratedTitle(ride.title) {
            ride.title = RideTitleGenerator.make(
                startTime: ride.startTime,
                persona: ride.ridePersona,
                points: ride.points ?? []
            )
            ride.isSynced = false
            changed = true
        }

        do {
            if changed { try context.save() }
            defaults.set(true, forKey: Self.personaTitleMigrationKey)
        } catch {
            NSLog("TrackMe: failed to migrate generated persona titles: %@", error.localizedDescription)
        }
    }

    /// Deletes ALL locally-stored rides, GPS points, and legacy retired emergency records.
    /// Serialized behind any pending point writes so a concurrent background insert can't resurrect a row after the wipe.
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
        try? context.delete(model: EmergencyContact.self)
        try? context.delete(model: EmergencySettings.self)
        try context.save()
    }

}
