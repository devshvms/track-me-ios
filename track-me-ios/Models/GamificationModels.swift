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
    public let currentLevelNameKey: String
    public let currentMinutes: Int64
    public let currentThresholdMinutes: Int64
    public let nextThresholdMinutes: Int64?
    public let progressNumeratorMinutes: Int64
    public let progressDenominatorMinutes: Int64
    public let latestUnlockedMilestoneId: String?
    public let unlockedMilestoneIds: [String]
    public let unlockedMilestoneCount: Int

    public init(
        currentLevelId: String,
        currentLevelNameKey: String,
        currentMinutes: Int64,
        currentThresholdMinutes: Int64,
        nextThresholdMinutes: Int64?,
        progressNumeratorMinutes: Int64,
        progressDenominatorMinutes: Int64,
        latestUnlockedMilestoneId: String?,
        unlockedMilestoneIds: [String],
        unlockedMilestoneCount: Int
    ) {
        self.currentLevelId = currentLevelId
        self.currentLevelNameKey = currentLevelNameKey
        self.currentMinutes = currentMinutes
        self.currentThresholdMinutes = currentThresholdMinutes
        self.nextThresholdMinutes = nextThresholdMinutes
        self.progressNumeratorMinutes = progressNumeratorMinutes
        self.progressDenominatorMinutes = progressDenominatorMinutes
        self.latestUnlockedMilestoneId = latestUnlockedMilestoneId
        self.unlockedMilestoneIds = unlockedMilestoneIds
        self.unlockedMilestoneCount = unlockedMilestoneCount
    }
}
