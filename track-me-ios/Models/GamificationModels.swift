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
    /// TASK-276: the real qualifying activity count, so the rail can state it rather than showing
    /// the last milestone's threshold and calling it "recorded".
    public let currentActivityCount: Int
    public let currentThresholdMinutes: Int64
    public let nextThresholdMinutes: Int64?
    /// SCOPE_1.8.7 §6.1.2 #10b needs to *name* the next level, not just count minutes to it.
    ///
    /// Defaulted so the existing constructions of this snapshot are untouched — and nil at the
    /// maximum level, where ``nextThresholdMinutes`` is nil too.
    public let nextLevelNameKey: String?
    public let progressNumeratorMinutes: Int64
    public let progressDenominatorMinutes: Int64
    public let latestUnlockedMilestoneId: String?
    public let unlockedMilestoneIds: [String]
    public let unlockedMilestoneCount: Int

    public init(
        currentLevelId: String,
        currentLevelNameKey: String,
        currentMinutes: Int64,
        currentActivityCount: Int,
        currentThresholdMinutes: Int64,
        nextThresholdMinutes: Int64?,
        nextLevelNameKey: String? = nil,
        progressNumeratorMinutes: Int64,
        progressDenominatorMinutes: Int64,
        latestUnlockedMilestoneId: String?,
        unlockedMilestoneIds: [String],
        unlockedMilestoneCount: Int
    ) {
        self.currentLevelId = currentLevelId
        self.currentLevelNameKey = currentLevelNameKey
        self.currentMinutes = currentMinutes
        self.currentActivityCount = currentActivityCount
        self.currentThresholdMinutes = currentThresholdMinutes
        self.nextThresholdMinutes = nextThresholdMinutes
        self.nextLevelNameKey = nextLevelNameKey
        self.progressNumeratorMinutes = progressNumeratorMinutes
        self.progressDenominatorMinutes = progressDenominatorMinutes
        self.latestUnlockedMilestoneId = latestUnlockedMilestoneId
        self.unlockedMilestoneIds = unlockedMilestoneIds
        self.unlockedMilestoneCount = unlockedMilestoneCount
    }
}
