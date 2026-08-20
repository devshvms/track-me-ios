import Foundation

/// Canonical ride used by the onboarding demos and, later, the first-run sample ride.
///
/// The route is synthetic and centered on a public park; it is not captured user location data.
/// The returned SwiftData model graph is deliberately detached from every `ModelContext`.
enum OnboardingDemoFixture {
    static let referenceStartTime = Date(timeIntervalSince1970: 1_767_225_600)
    static let duration: TimeInterval = 540
    static let distanceMeters = 1_931.404579
    static let averageSpeedMetersPerSecond = distanceMeters / duration
    static let maxSpeedMetersPerSecond = 4.13
    static let pointCount = 31

    private struct Sample {
        let latitude: Double
        let longitude: Double
        let altitudeMeters: Double
        let speedMetersPerSecond: Double
        let accuracyMeters: Double

        func midpoint(to next: Sample) -> Sample {
            Sample(
                latitude: (latitude + next.latitude) / 2,
                longitude: (longitude + next.longitude) / 2,
                altitudeMeters: (altitudeMeters + next.altitudeMeters) / 2,
                speedMetersPerSecond: (speedMetersPerSecond + next.speedMetersPerSecond) / 2,
                accuracyMeters: (accuracyMeters + next.accuracyMeters) / 2
            )
        }
    }

    private static let anchors = [
        Sample(latitude: 12.976698, longitude: 77.592085, altitudeMeters: 918, speedMetersPerSecond: 2.80, accuracyMeters: 5.2),
        Sample(latitude: 12.977342, longitude: 77.592805, altitudeMeters: 920, speedMetersPerSecond: 2.94, accuracyMeters: 4.8),
        Sample(latitude: 12.977882, longitude: 77.593810, altitudeMeters: 923, speedMetersPerSecond: 3.45, accuracyMeters: 4.5),
        Sample(latitude: 12.978108, longitude: 77.595055, altitudeMeters: 927, speedMetersPerSecond: 3.81, accuracyMeters: 4.2),
        Sample(latitude: 12.977747, longitude: 77.596375, altitudeMeters: 931, speedMetersPerSecond: 4.13, accuracyMeters: 4.0),
        Sample(latitude: 12.976982, longitude: 77.597350, altitudeMeters: 934, speedMetersPerSecond: 3.77, accuracyMeters: 4.1),
        Sample(latitude: 12.976008, longitude: 77.597755, altitudeMeters: 936, speedMetersPerSecond: 3.25, accuracyMeters: 4.4),
        Sample(latitude: 12.974898, longitude: 77.597440, altitudeMeters: 935, speedMetersPerSecond: 3.56, accuracyMeters: 4.7),
        Sample(latitude: 12.973923, longitude: 77.596690, altitudeMeters: 932, speedMetersPerSecond: 3.76, accuracyMeters: 5.0),
        Sample(latitude: 12.973247, longitude: 77.595655, altitudeMeters: 928, speedMetersPerSecond: 3.75, accuracyMeters: 5.3),
        Sample(latitude: 12.973022, longitude: 77.594425, altitudeMeters: 924, speedMetersPerSecond: 3.77, accuracyMeters: 5.1),
        Sample(latitude: 12.973382, longitude: 77.593210, altitudeMeters: 921, speedMetersPerSecond: 3.82, accuracyMeters: 4.8),
        Sample(latitude: 12.974208, longitude: 77.592265, altitudeMeters: 919, speedMetersPerSecond: 3.82, accuracyMeters: 4.5),
        Sample(latitude: 12.975258, longitude: 77.591725, altitudeMeters: 920, speedMetersPerSecond: 3.63, accuracyMeters: 4.3),
        Sample(latitude: 12.976247, longitude: 77.591680, altitudeMeters: 922, speedMetersPerSecond: 3.06, accuracyMeters: 4.6),
        Sample(latitude: 12.977148, longitude: 77.592160, altitudeMeters: 921, speedMetersPerSecond: 3.14, accuracyMeters: 4.9)
    ]

    // Keep samples below ChartAccessibility's 25-second signal-gap threshold without inventing a
    // second route. Midpoints preserve the same path, aggregate distance, and elevation profile.
    private static let samples = anchors.enumerated().flatMap { index, sample in
        guard index < anchors.count - 1 else { return [sample] }
        return [sample, sample.midpoint(to: anchors[index + 1])]
    }

    /// Builds a detached model graph. The caller supplies any user-facing title so it can be
    /// localized; `nil` lets the existing ride-title fallback render normally.
    static func makeRide(
        startTime: Date = referenceStartTime,
        title: String? = nil
    ) -> Ride {
        let ride = Ride(
            startTime: startTime,
            sourceInfo: "TrackMe Onboarding Sample",
            title: title
        )
        ride.endTime = startTime.addingTimeInterval(duration)
        ride.persona = RidePersona.cycling.rawValue
        ride.distanceMeters = distanceMeters
        ride.movingDurationMillis = Int64(duration * 1_000)
        ride.maxSpeedMps = maxSpeedMetersPerSecond
        ride.avgSpeedMps = averageSpeedMetersPerSecond
        ride.pointCount = pointCount

        let interval = duration / Double(samples.count - 1)
        let points = samples.enumerated().map { index, sample in
            GPSPoint(
                latitude: sample.latitude,
                longitude: sample.longitude,
                altitude: sample.altitudeMeters,
                accuracy: sample.accuracyMeters,
                speed: sample.speedMetersPerSecond,
                timestamp: startTime.addingTimeInterval(interval * Double(index)),
                ride: ride
            )
        }
        ride.points = points
        return ride
    }
}
