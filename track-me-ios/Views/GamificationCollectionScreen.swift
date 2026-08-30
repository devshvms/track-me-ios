import SwiftUI

public struct GamificationCollectionScreen: View {
    public let snapshot: GamificationSnapshot
    @Environment(\.dismiss) private var dismiss
    
    private let allLevels = ["level_1", "level_2", "level_3", "level_4", "level_5", "level_6"]
    private let allMilestones = [
        "milestone_1", "milestone_10", "milestone_25", "milestone_50", 
        "milestone_100", "milestone_250", "milestone_500", "milestone_1000"
    ]
    
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
                    
                    let currentIndex = allLevels.firstIndex(of: snapshot.currentLevelId) ?? 0
                    
                    ForEach(Array(allLevels.enumerated()), id: \.element) { index, level in
                        let isUnlocked = index <= currentIndex
                        let statusText = isUnlocked ? GamificationStringsHelper.unlocked : GamificationStringsHelper.locked
                        
                        HStack {
                            VStack(alignment: .leading) {
                                Text(GamificationStringsHelper.levelName(for: level))
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
                    }
                }
                
                // Milestones
                VStack(alignment: .leading, spacing: 8) {
                    Text(GamificationStringsHelper.milestones)
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    ForEach(allMilestones, id: \.self) { milestone in
                        let isUnlocked = snapshot.unlockedMilestoneIds.contains(milestone)
                        let statusText = isUnlocked ? GamificationStringsHelper.unlocked : GamificationStringsHelper.locked
                        
                        HStack {
                            VStack(alignment: .leading) {
                                Text(GamificationStringsHelper.milestoneTitle(for: milestone))
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
                    }
                }
                
            }
            .padding()
        }
        .navigationTitle(GamificationStringsHelper.myProgress)
        .navigationBarTitleDisplayMode(.inline)
    }
}
