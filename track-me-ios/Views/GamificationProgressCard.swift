import SwiftUI

public struct GamificationProgressCard: View {
    public let snapshot: GamificationSnapshot
    public let facts: GamificationFacts
    public let onOpenProgress: () -> Void
    
    public init(snapshot: GamificationSnapshot, facts: GamificationFacts, onOpenProgress: @escaping () -> Void) {
        self.snapshot = snapshot
        self.facts = facts
        self.onOpenProgress = onOpenProgress
    }
    
    public var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "star.fill")
                        .foregroundColor(BrandColor.primary)
                    Text(GamificationStringsHelper.myProgress)
                        .font(.headline)
                        .fontWeight(.bold)
                }
                
                Text(GamificationStringsHelper.levelName(for: snapshot.currentLevelId))
                    .font(.title2)
                
                let currentMinutes = Int(max(0, facts.lifetimeActiveDurationMillis) / 60_000)
                let nextThreshold = snapshot.nextLevelDurationThresholdMillis ?? facts.lifetimeActiveDurationMillis
                let nextMinutes = Int(nextThreshold / 60_000)
                
                let progressRatio = nextMinutes > 0 ? min(1.0, max(0.0, Double(currentMinutes) / Double(nextMinutes))) : 1.0
                let progressStr = LocalizationHelper.formatted("%d / %d mins", currentMinutes, nextMinutes)
                
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progressRatio)
                        .progressViewStyle(LinearProgressViewStyle(tint: BrandColor.primary))
                    Text(progressStr)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(progressStr)
                
                if let milestone = snapshot.unlockedMilestoneIds.last {
                    Text(GamificationStringsHelper.milestoneTitle(for: milestone))
                        .font(.subheadline)
                }
                
                Button(action: onOpenProgress) {
                    Text(GamificationStringsHelper.viewProgress)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(18)
        }
    }
}
