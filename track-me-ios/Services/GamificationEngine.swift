import Foundation

public enum GamificationEngine: Sendable {
    private static let LEVEL_THRESHOLDS: [(threshold: Int64, id: String)] = [
        (7_200_000, "level_2"),
        (36_000_000, "level_3"),
        (108_000_000, "level_4"),
        (270_000_000, "level_5"),
        (540_000_000, "level_6")
    ]

    private static let MILESTONES: [(count: Int, id: String)] = [
        (1, "milestone_1"),
        (10, "milestone_10"),
        (25, "milestone_25"),
        (50, "milestone_50"),
        (100, "milestone_100"),
        (250, "milestone_250"),
        (500, "milestone_500"),
        (1000, "milestone_1000")
    ]

    public static func deriveSnapshot(facts: GamificationFacts) -> GamificationSnapshot {
        let duration = facts.lifetimeActiveDurationMillis
        
        var currentLevelId = "level_1"
        var nextThreshold: Int64? = LEVEL_THRESHOLDS.first?.threshold

        for (index, threshold) in LEVEL_THRESHOLDS.enumerated() {
            if duration >= threshold.threshold {
                currentLevelId = threshold.id
                let nextIndex = index + 1
                if nextIndex < LEVEL_THRESHOLDS.count {
                    nextThreshold = LEVEL_THRESHOLDS[nextIndex].threshold
                } else {
                    nextThreshold = nil
                }
            } else {
                break
            }
        }

        let unlockedMilestones = MILESTONES
            .filter { facts.lifetimeActivityCount >= $0.count }
            .map { $0.id }
            .sorted()

        return GamificationSnapshot(
            currentLevelId: currentLevelId,
            nextLevelDurationThresholdMillis: nextThreshold,
            unlockedMilestoneIds: unlockedMilestones
        )
    }
}
