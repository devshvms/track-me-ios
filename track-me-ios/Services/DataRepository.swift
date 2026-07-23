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

    func finishRide(rideId: UUID) {
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

                if ride.title == nil || ride.title?.isEmpty == true {
                    ride.title = RideTitleGenerator.make(startTime: ride.startTime, points: ride.points ?? [])
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

    func getEmergencySettings() -> EmergencySettings {
        guard let container = container else {
            return EmergencySettings()
        }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<EmergencySettings>()
        do {
            if let settings = try context.fetch(descriptor).first {
                return settings
            } else {
                let newSettings = EmergencySettings()
                context.insert(newSettings)
                try context.save()
                return newSettings
            }
        } catch {
            return EmergencySettings()
        }
    }

    func disableEmergencySetup() {
        guard let container = container else { return }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<EmergencySettings>()
        if let settings = try? context.fetch(descriptor).first {
            settings.isSetupComplete = false
            try? context.save()
        }
    }
}
