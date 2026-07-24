import Foundation
import CoreLocation
import SwiftData
import os.log

enum RideMetrics {
    /// Naive point-to-point sum (drift-inflated). ONLY for legacy fallback /
    /// detail-chart cumulative distances — NOT the source of truth for a ride's
    /// distance. Finalize persists the live value instead.
    static func rawDistanceMeters(_ points: [GPSPoint]) -> Double {
        guard points.count > 1 else { return 0 }
        let sorted = points.sorted { $0.timestamp < $1.timestamp }
        var total = 0.0
        for i in 1..<sorted.count {
            let a = CLLocation(latitude: sorted[i-1].latitude, longitude: sorted[i-1].longitude)
            let b = CLLocation(latitude: sorted[i].latitude, longitude: sorted[i].longitude)
            total += b.distance(from: a)
        }
        return total
    }
}

@MainActor
struct RideAggregateBackfill {
    private static let logger = Logger(subsystem: "com.trackme.ios", category: "RideAggregateBackfill")
    
    static func run(container: ModelContainer) async {
        let context = ModelContext(container)
        
        let descriptor = FetchDescriptor<Ride>(predicate: #Predicate { $0.distanceMeters == nil })
        do {
            let ridesToBackfill = try context.fetch(descriptor)
            guard !ridesToBackfill.isEmpty else { return }
            
            logger.info("Starting backfill for \(ridesToBackfill.count) legacy rides.")
            
            var batchCount = 0
            for ride in ridesToBackfill {
                let pts = ride.points ?? []
                let distance = RideMetrics.rawDistanceMeters(pts)
                let count = pts.count
                // Avoid backfilling rides that are still recording (endTime == nil)
                guard let endTime = ride.endTime else { continue }
                
                let movingMillis = Int(endTime.timeIntervalSince(ride.startTime) * 1000)
                let maxSpeed = pts.map { $0.speed }.max() ?? 0.0
                let avgSpeed = movingMillis > 0 ? distance / (Double(movingMillis) / 1000.0) : 0.0
                
                ride.distanceMeters = distance
                ride.movingDurationMillis = movingMillis
                ride.pointCount = count
                ride.maxSpeedMps = maxSpeed
                ride.avgSpeedMps = avgSpeed
                
                batchCount += 1
                if batchCount % 25 == 0 {
                    try context.save()
                }
            }
            if batchCount % 25 != 0 {
                try context.save()
            }
            logger.info("Successfully backfilled \(batchCount) legacy rides.")
        } catch {
            logger.error("Failed to backfill legacy rides: \(error.localizedDescription)")
        }
    }
}
