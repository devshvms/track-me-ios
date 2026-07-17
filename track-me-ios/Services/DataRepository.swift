import Foundation
import SwiftData

@MainActor
final class DataRepository {
    static let shared = DataRepository()
    var container: ModelContainer?
    
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
        
        Task {
            let context = ModelContext(container)
            // Fetch the ride using id safely in background context
            let descriptor = FetchDescriptor<Ride>(predicate: #Predicate { $0.id == rideId })
            if let ride = try? context.fetch(descriptor).first {
                let point = GPSPoint(latitude: lat, longitude: lng, altitude: alt, accuracy: acc, speed: spd, timestamp: ts, isPaused: paused)
                ride.points?.append(point)
                context.insert(point)
                try? context.save()
            }
        }
    }
    
    func finishRide(rideId: UUID) {
        guard let container = container else { return }
        Task {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<Ride>(predicate: #Predicate { $0.id == rideId })
            if let ride = try? context.fetch(descriptor).first {
                ride.endTime = Date()
                
                if ride.title == nil || ride.title?.isEmpty == true {
                    var maxSpeed: Double = 0
                    if let pts = ride.points {
                        for p in pts {
                            maxSpeed = max(maxSpeed, p.speed)
                        }
                    }
                    
                    // Convert speed from m/s to km/h
                    let maxSpeedKmh = maxSpeed * 3.6
                    let activity = maxSpeedKmh > 15.0 ? "Bike Ride" : "Walk/Run"
                    
                    let hour = Calendar.current.component(.hour, from: ride.startTime)
                    let timeOfDay: String
                    switch hour {
                    case 5...11: timeOfDay = "Morning"
                    case 12...16: timeOfDay = "Afternoon"
                    case 17...20: timeOfDay = "Evening"
                    default: timeOfDay = "Night"
                    }
                    
                    ride.title = "\(timeOfDay) \(activity)"
                }
                
                try? context.save()
                
                // Fire and forget cloud sync
                FirestoreSyncManager.shared.syncRide(ride)
            }
        }
    }
}
