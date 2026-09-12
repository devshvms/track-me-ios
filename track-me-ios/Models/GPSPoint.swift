import Foundation
import SwiftData
import CoreLocation

@Model
final class GPSPoint {
    @Attribute(.unique) var id: UUID
    var latitude: Double
    var longitude: Double

    /// Presentation-only geometry emitted by Tracking V2. Raw latitude/longitude remain the
    /// immutable recording evidence used by GPX export, diagnostics and future reprocessing.
    var displayLatitude: Double? = nil
    var displayLongitude: Double? = nil

    var rawCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var coordinate: CLLocationCoordinate2D {
        guard let displayLatitude, let displayLongitude else { return rawCoordinate }
        let candidate = CLLocationCoordinate2D(
            latitude: displayLatitude,
            longitude: displayLongitude
        )
        return CLLocationCoordinate2DIsValid(candidate) ? candidate : rawCoordinate
    }
    var altitude: Double
    var accuracy: Double
    var speed: Double
    var timestamp: Date
    var isPaused: Bool
    var cumulativeDistanceMeters: Double? = nil
    
    var ride: Ride?
    
    init(
        id: UUID = UUID(),
        latitude: Double,
        longitude: Double,
        altitude: Double,
        accuracy: Double,
        speed: Double,
        timestamp: Date,
        isPaused: Bool = false,
        displayLatitude: Double? = nil,
        displayLongitude: Double? = nil,
        ride: Ride? = nil
    ) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.displayLatitude = displayLatitude
        self.displayLongitude = displayLongitude
        self.altitude = altitude
        self.accuracy = accuracy
        self.speed = speed
        self.timestamp = timestamp
        self.isPaused = isPaused
        self.ride = ride
    }
}
