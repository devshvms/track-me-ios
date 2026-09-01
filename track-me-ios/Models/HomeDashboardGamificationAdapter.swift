import Foundation

extension HomeDashboardSummary {
    func toGamificationFacts() -> GamificationFacts {
        GamificationFacts(
            // TASK-275: deliberately the gamification pair, not the dashboard pair. Imported
            // rides appear everywhere else and earn nothing here.
            lifetimeActivityCount: self.gamificationActivityCount,
            lifetimeActiveDurationMillis: self.gamificationActiveDurationMillis
        )
    }
}
