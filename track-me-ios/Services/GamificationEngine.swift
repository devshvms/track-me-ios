import Foundation

enum GamificationEngine {
    
    /// Core qualification rule from GAMIFICATION.md SS3
    static func isQualifyingRide(_ ride: Ride) -> Bool {
        if ride.isSample { return false }
        if ride.pendingDelete { return false }
        
        let duration = ride.movingDurationMillis ?? 0
        if duration < 5 * 60 * 1000 { return false }
        
        if !ride.qualifiesForStats { return false }
        
        return true
    }

    static func isQualifyingGroupRide(_ ride: Ride) -> Bool {
        guard isQualifyingRide(ride) else { return false }
        guard ride.wasGroupRide else { return false }
        guard (ride.groupRiderCount ?? 0) > 1 else { return false }
        return true
    }

    static func calculateTotalActiveMinutes(from rides: [Ride]) -> Int64 {
        return rides
            .filter { isQualifyingRide($0) }
            .compactMap { $0.movingDurationMillis }
            .reduce(0, +) / 60000
    }

    static func calculateLevel(from rides: [Ride]) -> GamificationLevel {
        let minutes = calculateTotalActiveMinutes(from: rides)
        return GamificationDefinitions.getLevel(forMinutes: minutes)
    }

    static func getUnlockedAchievements(from rides: [Ride]) -> [String] {
        var unlocked = [String]()
        let qualifyingRides = rides.filter { isQualifyingRide($0) }
        
        if qualifyingRides.isEmpty { return unlocked }

        unlocked.append("First Qualifying Activity")
        
        if qualifyingRides.count >= 5 {
            unlocked.append("Getting Moving")
        }

        let totalMinutes = calculateTotalActiveMinutes(from: qualifyingRides)
        if totalMinutes >= 6000 {
            unlocked.append("Hundred Hours")
        }

        let groupRides = qualifyingRides.filter { isQualifyingGroupRide($0) }
        if !groupRides.isEmpty {
            unlocked.append("Together")
        }
        if groupRides.count >= 5 {
            unlocked.append("Social Five")
        }
        if groupRides.contains(where: { ($0.groupRiderCount ?? 0) >= 10 }) {
            unlocked.append("Full Crew")
        }
        
        let groupDistance = groupRides.compactMap { $0.distanceMeters }.reduce(0.0, +)
        if groupDistance >= 100_000.0 {
            unlocked.append("Distance Together")
        }
        
        let distinctPersonas = Set(qualifyingRides.map { $0.persona }.filter { $0 != "AUTO" })
        if distinctPersonas.count >= 3 {
            unlocked.append("Multi-Move")
        }

        return unlocked
    }
}
