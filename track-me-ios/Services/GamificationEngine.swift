import Foundation

public struct GamificationLevelDefinition: Equatable, Sendable {
    public let id: String
    public let nameKey: String
    public let thresholdMinutes: Int64
}

public struct GamificationMilestoneDefinition: Equatable, Sendable {
    public let id: String
    public let activityCount: Int
}

public enum GamificationEngine: Sendable {
    public static let levels: [GamificationLevelDefinition] = [
        GamificationLevelDefinition(id: "level_1", nameKey: "Starter", thresholdMinutes: 0),
        GamificationLevelDefinition(id: "level_2", nameKey: "Moving", thresholdMinutes: 120),
        GamificationLevelDefinition(id: "level_3", nameKey: "Regular", thresholdMinutes: 600),
        GamificationLevelDefinition(id: "level_4", nameKey: "Explorer", thresholdMinutes: 1_800),
        GamificationLevelDefinition(id: "level_5", nameKey: "Enduring", thresholdMinutes: 4_500),
        GamificationLevelDefinition(id: "level_6", nameKey: "Pathfinder", thresholdMinutes: 9_000)
    ]

    public static let milestones: [GamificationMilestoneDefinition] = [
        GamificationMilestoneDefinition(id: "milestone_1", activityCount: 1),
        GamificationMilestoneDefinition(id: "milestone_10", activityCount: 10),
        GamificationMilestoneDefinition(id: "milestone_25", activityCount: 25),
        GamificationMilestoneDefinition(id: "milestone_50", activityCount: 50),
        GamificationMilestoneDefinition(id: "milestone_100", activityCount: 100),
        GamificationMilestoneDefinition(id: "milestone_250", activityCount: 250),
        GamificationMilestoneDefinition(id: "milestone_500", activityCount: 500),
        GamificationMilestoneDefinition(id: "milestone_1000", activityCount: 1_000)
    ]

    public static func deriveSnapshot(facts: GamificationFacts) -> GamificationSnapshot {
        let currentMinutes = max(0, facts.lifetimeActiveDurationMillis) / 60_000
        let activityCount = max(0, facts.lifetimeActivityCount)
        let currentLevel = levels.last { currentMinutes >= $0.thresholdMinutes } ?? levels[0]
        let nextLevel = levels.first { $0.thresholdMinutes > currentMinutes }
        let progressDenominator = nextLevel.map {
            $0.thresholdMinutes - currentLevel.thresholdMinutes
        } ?? 0
        let progressNumerator = nextLevel == nil
            ? 0
            : min(progressDenominator, max(0, currentMinutes - currentLevel.thresholdMinutes))

        // Preserve catalogue order. Lexicographic sorting would put milestone_1000 before
        // milestone_25 and make the Home card announce the wrong "latest" unlock.
        let unlockedMilestones = milestones
            .filter { activityCount >= $0.activityCount }
            .map { $0.id }

        return GamificationSnapshot(
            currentLevelId: currentLevel.id,
            currentLevelNameKey: currentLevel.nameKey,
            currentMinutes: currentMinutes,
            currentThresholdMinutes: currentLevel.thresholdMinutes,
            nextThresholdMinutes: nextLevel?.thresholdMinutes,
            progressNumeratorMinutes: progressNumerator,
            progressDenominatorMinutes: progressDenominator,
            latestUnlockedMilestoneId: unlockedMilestones.last,
            unlockedMilestoneIds: unlockedMilestones,
            unlockedMilestoneCount: unlockedMilestones.count
        )
    }
}
