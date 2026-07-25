import CoreLocation

enum RideDistance {
    static func meters(_ points: [GPSPoint]) -> Double {
        guard points.count > 1 else { return 0 }
        return zip(points, points.dropFirst()).reduce(0) { total, pair in
            total + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
        }
    }
    static func kilometers(_ points: [GPSPoint]) -> Double { meters(points) / 1000 }
}
