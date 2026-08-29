import SwiftUI

struct GamificationProgressCard: View {
    let currentLevel: GamificationLevel
    let totalActiveMinutes: Int64
    let unlockedAchievements: [String]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Level \(currentLevel.level): \(currentLevel.name)")
                .font(.headline)
            
            let nextLevel = GamificationDefinitions.levels.first { $0.level == currentLevel.level + 1 }
            
            VStack(spacing: 6) {
                HStack {
                    Text("\(totalActiveMinutes) active minutes")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let next = nextLevel {
                        Text("\(next.requiredActiveMinutes) for \(next.name)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Max level reached")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                
                GeometryReader { proxy in
                    let progress: CGFloat = {
                        guard let next = nextLevel else { return 1.0 }
                        let range = CGFloat(next.requiredActiveMinutes - currentLevel.requiredActiveMinutes)
                        let current = CGFloat(totalActiveMinutes - currentLevel.requiredActiveMinutes)
                        return min(1.0, max(0.0, current / range))
                    }()
                    
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                        RoundedRectangle(cornerRadius: 4)
                            .fill(BrandColor.primary)
                            .frame(width: proxy.size.width * progress)
                    }
                }
                .frame(height: 8)
            }
            
            HStack(spacing: 8) {
                Image(systemName: unlockedAchievements.isEmpty ? "star" : "star.fill")
                    .foregroundColor(BrandColor.primary)
                Text("\(unlockedAchievements.count) Achievements Unlocked")
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}
