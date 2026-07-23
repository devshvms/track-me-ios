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
