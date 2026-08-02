import CoreLocation

enum RoutePrivacyTrim {
    static func distanceMeters(_ from: GPSPoint, _ to: GPSPoint) -> Double {
        CLLocation(latitude: from.latitude, longitude: from.longitude)
            .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
    }

    /// Returns a presentation-only route trimmed at both ends. Stored points are never mutated.
    static func trim(_ points: [GPSPoint], trimMeters: Double) -> [GPSPoint] {
        guard points.count >= 2, trimMeters > 0 else { return points }

        var segmentDistances = [Double](repeating: 0, count: points.count - 1)
        var totalMeters = 0.0
        for index in segmentDistances.indices {
            let segment = max(0, distanceMeters(points[index], points[index + 1]))
            segmentDistances[index] = segment
            totalMeters += segment
        }

        guard totalMeters > trimMeters * 2 else { return points }

        var startIndex = 0
        var startMeters = 0.0
        while startIndex < points.count - 1 && startMeters < trimMeters {
            startMeters += segmentDistances[startIndex]
            startIndex += 1
        }

        var endIndex = points.count - 1
        var endMeters = 0.0
        while endIndex > 0 && endMeters < trimMeters {
            endMeters += segmentDistances[endIndex - 1]
            endIndex -= 1
        }

        return startIndex < endIndex ? Array(points[startIndex...endIndex]) : points
    }
}
