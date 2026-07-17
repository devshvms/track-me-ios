import Foundation
import SwiftData
import CoreLocation

@Model
final class GPSPoint {
    @Attribute(.unique) var id: UUID
    var latitude: Double
    var longitude: Double
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    var altitude: Double
    var accuracy: Double
    var speed: Double
    var timestamp: Date
    var isPaused: Bool
    
    var ride: Ride?
    
    init(id: UUID = UUID(), latitude: Double, longitude: Double, altitude: Double, accuracy: Double, speed: Double, timestamp: Date, isPaused: Bool = false, ride: Ride? = nil) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.accuracy = accuracy
        self.speed = speed
        self.timestamp = timestamp
        self.isPaused = isPaused
        self.ride = ride
    }
}
