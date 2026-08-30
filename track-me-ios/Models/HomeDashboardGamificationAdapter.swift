import Foundation

public extension HomeDashboardSummary {
    func toGamificationFacts() -> GamificationFacts {
        GamificationFacts(
            lifetimeActivityCount: self.lifetimeActivityCount,
            lifetimeActiveDurationMillis: self.lifetimeActiveDurationMillis
        )
    }
}
