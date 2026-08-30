import SwiftUI

public struct GamificationProgressCard: View {
    public let snapshot: GamificationSnapshot
    public let onOpenProgress: () -> Void

    public init(snapshot: GamificationSnapshot, onOpenProgress: @escaping () -> Void) {
        self.snapshot = snapshot
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
                
                Text(GamificationStringsHelper.levelName(forNameKey: snapshot.currentLevelNameKey))
                    .font(.title2)

                VStack(alignment: .leading, spacing: 4) {
                    if let nextThreshold = snapshot.nextThresholdMinutes {
                        ProgressView(
                            value: Double(snapshot.progressNumeratorMinutes),
                            total: Double(max(1, snapshot.progressDenominatorMinutes))
                        )
                        .progressViewStyle(.linear)
                        .tint(BrandColor.primary)
                        Text(GamificationStringsHelper.nextLevelProgress(
                            current: snapshot.currentMinutes,
                            next: nextThreshold
                        ))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    } else {
                        Text(GamificationStringsHelper.maximumLevel(current: snapshot.currentMinutes))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)

                if let milestoneId = snapshot.latestUnlockedMilestoneId,
                   let milestone = GamificationEngine.milestones.first(where: { $0.id == milestoneId }) {
                    Text(GamificationStringsHelper.latestMilestone)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(GamificationStringsHelper.milestoneTitle(activityCount: milestone.activityCount))
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
