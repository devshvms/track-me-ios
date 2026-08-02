import Foundation

enum ReplayStatsInterpolation {
    static func replayStatsAtProgress(
        points: [GPSPoint],
        progress: Float,
        fallback: ReplayStats
    ) -> ReplayStats {
        guard points.count >= 2 else { return fallback }

        let totalDistance = fallback.distanceMeters > 0
            ? fallback.distanceMeters
            : geometricRouteDistanceMeters(points)
        let span = points.last!.timestamp.timeIntervalSince(points.first!.timestamp)
        let totalDuration = fallback.durationMillis > 0
            ? fallback.durationMillis
            : Int64(max(0, span * 1000))

        let distance = totalDistance * routeDistanceFraction(points: points, progress: progress)
        let duration = Int64(Double(totalDuration) * routeTimeFraction(points: points, progress: progress))
        let averageSpeed = duration > 0 ? distance / (Double(duration) / 1000) : 0
        return ReplayStats(distanceMeters: distance, durationMillis: max(0, duration), averageSpeedMetersPerSecond: averageSpeed)
    }

    static func geometricRouteDistanceMeters(_ points: [GPSPoint]) -> Double {
        guard points.count >= 2 else { return 0 }
        return zip(points, points.dropFirst()).reduce(0) { total, pair in
            total + RoutePrivacyTrim.distanceMeters(pair.0, pair.1)
        }
    }

    static func routeDistanceFraction(points: [GPSPoint], progress: Float) -> Double {
        guard points.count >= 2 else { return 0 }
        let total = geometricRouteDistanceMeters(points)
        let clampedProgress = Double(min(max(progress, 0), 1))
        guard total > 0 else { return clampedProgress }

        let position = clampedProgress * Double(points.count - 1)
        let lower = min(max(Int(position), 0), points.count - 1)
        let fraction = min(max(position - Double(lower), 0), 1)
        var travelled = 0.0
        if lower > 0 {
            for index in 0..<lower {
                travelled += RoutePrivacyTrim.distanceMeters(points[index], points[index + 1])
            }
        }
        if lower < points.count - 1 {
            travelled += RoutePrivacyTrim.distanceMeters(points[lower], points[lower + 1]) * fraction
        }
        return min(max(travelled / total, 0), 1)
    }

    static func routeTimeFraction(points: [GPSPoint], progress: Float) -> Double {
        guard points.count >= 2 else { return 0 }
        let span = points.last!.timestamp.timeIntervalSince(points.first!.timestamp)
        let clampedProgress = Double(min(max(progress, 0), 1))
        guard span > 0 else { return clampedProgress }

        let position = clampedProgress * Double(points.count - 1)
        let lower = min(max(Int(position), 0), points.count - 1)
        let fraction = min(max(position - Double(lower), 0), 1)
        let elapsed: TimeInterval
        if lower >= points.count - 1 {
            elapsed = span
        } else {
            let lowerElapsed = points[lower].timestamp.timeIntervalSince(points.first!.timestamp)
            let segment = points[lower + 1].timestamp.timeIntervalSince(points[lower].timestamp)
            elapsed = lowerElapsed + max(0, segment) * fraction
        }
        return min(max(elapsed / span, 0), 1)
    }

    /// Maps an output frame to route progress using timestamp-weighted interpolation.
    static func progressForFrame(points: [GPSPoint], frame: Int, frameCount: Int) -> Float {
        guard points.count >= 2, frameCount > 1 else { return 0 }
        let clampedFrame = min(max(frame, 0), frameCount - 1)
        let first = points[0].timestamp
        let last = points[points.count - 1].timestamp
        let span = last.timeIntervalSince(first)
        guard span > 0 else { return Float(clampedFrame) / Float(frameCount - 1) }

        let target = span * Double(clampedFrame) / Double(frameCount - 1)
        let upper = max(1, points.firstIndex { $0.timestamp.timeIntervalSince(first) >= target } ?? points.count - 1)
        let lower = upper - 1
        let lowerTime = points[lower].timestamp.timeIntervalSince(first)
        let segment = max(points[upper].timestamp.timeIntervalSince(points[lower].timestamp), 1 / 1000)
        let fraction = (target - lowerTime) / segment
        return Float(min(max((Double(lower) + fraction) / Double(points.count - 1), 0), 1))
    }
}
