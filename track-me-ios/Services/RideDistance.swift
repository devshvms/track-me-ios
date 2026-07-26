import CoreLocation

enum RideDistance {
    /// Total planar distance in meters over points ordered by timestamp.
    ///
    /// Ride points can arrive out of order after a recovery or cloud merge, so
    /// every presentation surface must normalize ordering before accumulating.
    static func totalMeters(_ points: [GPSPoint]) -> Double {
        guard points.count > 1 else { return 0 }
        let sorted = points.sorted { $0.timestamp < $1.timestamp }
        return zip(sorted, sorted.dropFirst()).reduce(0) { total, pair in
            total + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
        }
    }

    static func totalKm(_ points: [GPSPoint]) -> Double { totalMeters(points) / 1000 }

    // Compatibility aliases used by existing detail/export surfaces.
    static func meters(_ points: [GPSPoint]) -> Double { totalMeters(points) }
    static func kilometers(_ points: [GPSPoint]) -> Double { totalKm(points) }
}

struct HistoryRideMetrics {
    let distanceKm: Double
    let duration: TimeInterval
    let avgSpeedKmh: Double

    init(points: [GPSPoint], startTime: Date, endTime: Date?) {
        let rawDuration = (endTime ?? startTime).timeIntervalSince(startTime)
        distanceKm = RideDistance.totalKm(points)
        duration = max(0, rawDuration)
        avgSpeedKmh = Self.averageSpeedKmh(distanceKm: distanceKm, duration: duration)
    }

    static func averageSpeedKmh(distanceKm: Double, duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        return distanceKm / (duration / 3600.0)
    }
}

enum HistoryMetricFormat {
    static func km(_ value: Double) -> String {
        String(format: "%.1f km", value)
    }

    static func kmh(_ value: Double) -> String {
        String(format: "%.1f km/h", value)
    }

    static func duration(_ value: TimeInterval) -> String {
        let seconds = Int(max(0, value))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }
}
