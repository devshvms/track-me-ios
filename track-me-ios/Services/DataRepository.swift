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
                NSLog("TrackMe: failed to persist GPS point: %@", error.localizedDescription)
            }
        }
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
                NSLog("TrackMe: failed to finalize ride: %@", error.localizedDescription)
            }
        }
    }
}
