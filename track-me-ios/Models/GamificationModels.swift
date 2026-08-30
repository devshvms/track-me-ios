import Foundation

public struct GamificationFacts: Codable, Equatable, Sendable {
    public let lifetimeActivityCount: Int
    public let lifetimeActiveDurationMillis: Int64
    
    public init(lifetimeActivityCount: Int, lifetimeActiveDurationMillis: Int64) {
        self.lifetimeActivityCount = lifetimeActivityCount
        self.lifetimeActiveDurationMillis = lifetimeActiveDurationMillis
    }
}

public struct GamificationSnapshot: Codable, Equatable, Sendable {
    public let currentLevelId: String
    public let nextLevelDurationThresholdMillis: Int64?
    public let unlockedMilestoneIds: [String]
    
    public init(currentLevelId: String, nextLevelDurationThresholdMillis: Int64?, unlockedMilestoneIds: [String]) {
        self.currentLevelId = currentLevelId
        self.nextLevelDurationThresholdMillis = nextLevelDurationThresholdMillis
        self.unlockedMilestoneIds = unlockedMilestoneIds
    }
}
