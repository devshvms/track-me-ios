import SwiftUI

public struct GamificationCollectionScreen: View {
    public let snapshot: GamificationSnapshot
    
    public init(snapshot: GamificationSnapshot) {
        self.snapshot = snapshot
    }
    
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                
                // Levels
                VStack(alignment: .leading, spacing: 8) {
                    Text(GamificationStringsHelper.levels)
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    let currentIndex = GamificationEngine.levels.firstIndex {
                        $0.id == snapshot.currentLevelId
                    } ?? 0
                    
                    ForEach(Array(GamificationEngine.levels.enumerated()), id: \.element.id) { index, level in
                        let isUnlocked = index <= currentIndex
                        let statusText = isUnlocked ? GamificationStringsHelper.unlocked : GamificationStringsHelper.locked
                        
                        HStack {
                            VStack(alignment: .leading) {
                                Text(GamificationStringsHelper.levelName(forNameKey: level.nameKey))
                                    .font(.body)
                                    .foregroundColor(isUnlocked ? .primary : .secondary)
                                Text(GamificationStringsHelper.unlockCriterion(minutes: level.thresholdMinutes))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(statusText)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if isUnlocked {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(BrandColor.primary)
                            } else {
                                Image(systemName: "lock.fill")
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding()
                        .background(isUnlocked ? BrandColor.primary.opacity(0.1) : Color(.systemGray6))
                        .cornerRadius(8)
                        .accessibilityElement(children: .combine)
                    }
                }
                
                // Milestones
                VStack(alignment: .leading, spacing: 8) {
                    Text(GamificationStringsHelper.milestones)
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    ForEach(GamificationEngine.milestones, id: \.id) { milestone in
                        let isUnlocked = snapshot.unlockedMilestoneIds.contains(milestone.id)
                        let statusText = isUnlocked ? GamificationStringsHelper.unlocked : GamificationStringsHelper.locked
                        
                        HStack {
                            VStack(alignment: .leading) {
                                Text(GamificationStringsHelper.milestoneTitle(activityCount: milestone.activityCount))
                                    .font(.body)
                                    .foregroundColor(isUnlocked ? .primary : .secondary)
                                Text(statusText)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if isUnlocked {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(BrandColor.primary)
                            } else {
                                Image(systemName: "lock.fill")
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding()
                        .background(isUnlocked ? BrandColor.primary.opacity(0.1) : Color(.systemGray6))
                        .cornerRadius(8)
                        .accessibilityElement(children: .combine)
                    }
                }
                
            }
            .padding()
        }
        .navigationTitle(GamificationStringsHelper.myProgress)
        .navigationBarTitleDisplayMode(.inline)
    }
}
