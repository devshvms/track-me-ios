import Foundation
import CoreLocation

struct GPSProcessor {
    static let maxAccelerationG = 14.7 // m/s^2 (1.5G)
    static let autoPauseSpeedThreshold = 0.69 // m/s (~2.5 km/h)
    static let autoPauseWindow = 15.0 // seconds
    static let smoothingWindowSize = 5
    
    /// A. Outlier Removal & Acceleration Tracking
    static func isOutlier(current: CLLocation, previous: CLLocation) -> Bool {
        let distance = current.distance(from: previous)
        let timeDelta = current.timestamp.timeIntervalSince(previous.timestamp)
        
        guard timeDelta > 0 else { return true }
        
        let requiredSpeed = distance / timeDelta
        let previousSpeed = max(previous.speed, 0)
        let acceleration = abs(requiredSpeed - previousSpeed) / timeDelta
        
        return acceleration > maxAccelerationG
    }
    
    /// B. Altitude & Speed Smoothing
    static func smooth(points: [CLLocation], newPoint: CLLocation) -> CLLocation {
        var recentPoints = Array(points.suffix(smoothingWindowSize - 1))
        recentPoints.append(newPoint)
        
        let avgAltitude = recentPoints.map { $0.altitude }.reduce(0, +) / Double(recentPoints.count)
        let avgSpeed = recentPoints.map { max($0.speed, 0) }.reduce(0, +) / Double(recentPoints.count)
        
        return CLLocation(coordinate: newPoint.coordinate,
                          altitude: avgAltitude,
                          horizontalAccuracy: newPoint.horizontalAccuracy,
                          verticalAccuracy: newPoint.verticalAccuracy,
                          course: newPoint.course,
                          courseAccuracy: newPoint.courseAccuracy,
                          speed: avgSpeed,
                          speedAccuracy: newPoint.speedAccuracy,
                          timestamp: newPoint.timestamp)
    }
    
    /// C. Retroactive Auto-Pause Detection
    static func calculateAutoPause(recentPoints: [CLLocation]) -> Bool {
        guard let first = recentPoints.first, let last = recentPoints.last else { return false }
        let timeDelta = last.timestamp.timeIntervalSince(first.timestamp)
        if timeDelta < autoPauseWindow {
            return false
        }
        
        let totalSpeed = recentPoints.map { max($0.speed, 0) }.reduce(0, +)
        let avgSpeed = totalSpeed / Double(recentPoints.count)
        return avgSpeed < autoPauseSpeedThreshold
    }
}
