import SwiftUI

public struct GamificationCollectionScreen: View {
    public let snapshot: GamificationSnapshot

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(snapshot: GamificationSnapshot) {
        self.snapshot = snapshot
    }

    public var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 620 || dynamicTypeSize.isAccessibilitySize
            let horizontalPadding: CGFloat = compact ? 8 : 14
            let verticalPadding: CGFloat = compact ? 4 : 10
            let availableHeight = max(1, proxy.size.height - verticalPadding * 2)
            let availableWidth = max(1, proxy.size.width - horizontalPadding * 2)
            let levelsHeight = availableHeight * 0.08
            let orbitHeight = availableHeight * 0.59
            let summaryHeight = availableHeight * 0.11
            let milestonesHeight = availableHeight * 0.22
            let orbitSize = min(availableWidth, orbitHeight)
            let levelIndex = GamificationOrbitPresentation.levelIndex(for: snapshot)
            let accent = ProgressLevelPalette.accent(
                levelIndex: levelIndex,
                colorScheme: colorScheme
            )

            VStack(spacing: 0) {
                Text(GamificationStringsHelper.levels)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
                    .allowsTightening(true)
                    .frame(maxWidth: .infinity)
                    .frame(height: levelsHeight)
                    .accessibilityAddTraits(.isHeader)

                ZStack {
                    ProgressOrbitView(
                        snapshot: snapshot,
                        levelIndex: levelIndex,
                        accent: accent,
                        colorScheme: colorScheme,
                        compact: compact
                    )
                    .frame(width: orbitSize, height: orbitSize)
                }
                .frame(maxWidth: .infinity)
                .frame(height: orbitHeight)

                Text(progressSummary)
                    .font(.footnote)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.45)
                    .allowsTightening(true)
                    .frame(maxWidth: .infinity)
                    .frame(height: summaryHeight)
                    .accessibilityLabel(progressSummary)

                MilestoneConstellation(
                    snapshot: snapshot,
                    accent: accent,
                    colorScheme: colorScheme,
                    compact: compact
                )
                .frame(maxWidth: .infinity)
                .frame(height: milestonesHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background {
                LinearGradient(
                    colors: [
                        accent.opacity(colorScheme == .dark ? 0.18 : 0.12),
                        Color(uiColor: .systemBackground),
                        Color(uiColor: .secondarySystemBackground).opacity(0.72)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }
        }
        .navigationTitle(GamificationStringsHelper.myProgress)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var progressSummary: String {
        if let next = snapshot.nextThresholdMinutes {
            return GamificationStringsHelper.nextLevelProgress(
                current: snapshot.currentMinutes,
                next: next
            )
        }
        return GamificationStringsHelper.maximumLevel(current: snapshot.currentMinutes)
    }
}

enum GamificationOrbitPresentation {
    static func levelIndex(for snapshot: GamificationSnapshot) -> Int {
        max(
            0,
            GamificationEngine.levels.firstIndex { $0.id == snapshot.currentLevelId } ?? 0
        )
    }

    static func progress(for snapshot: GamificationSnapshot) -> Double {
        guard snapshot.progressDenominatorMinutes > 0 else {
            return levelIndex(for: snapshot) == GamificationEngine.levels.count - 1 ? 1 : 0
        }
        return min(
            1,
            max(
                0,
                Double(snapshot.progressNumeratorMinutes) /
                    Double(snapshot.progressDenominatorMinutes)
            )
        )
    }
}

private struct ProgressOrbitView: View {
    let snapshot: GamificationSnapshot
    let levelIndex: Int
    let accent: Color
    let colorScheme: ColorScheme
    let compact: Bool

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let centre = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let radius = size * (compact ? 0.385 : 0.39)
            let nodeSize = max(20, min(compact ? 42 : 48, size * 0.145))
            let dialSize = size * (compact ? 0.47 : 0.50)

            ZStack {
                Circle()
                    .fill(accent.opacity(colorScheme == .dark ? 0.11 : 0.08))
                    .frame(width: size * 0.72, height: size * 0.72)
                    .position(centre)

                Circle()
                    .stroke(
                        Color.secondary.opacity(colorScheme == .dark ? 0.25 : 0.16),
                        style: StrokeStyle(lineWidth: compact ? 11 : 14)
                    )
                    .frame(width: dialSize, height: dialSize)
                    .position(centre)

                Circle()
                    .trim(from: 0, to: GamificationOrbitPresentation.progress(for: snapshot))
                    .stroke(
                        accent,
                        style: StrokeStyle(
                            lineWidth: compact ? 11 : 14,
                            lineCap: .round
                        )
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: dialSize, height: dialSize)
                    .position(centre)

                VStack(spacing: compact ? 1 : 3) {
                    Text(GamificationStringsHelper.levelName(forNameKey: snapshot.currentLevelNameKey))
                        .font(compact ? .headline : .title3)
                        .fontWeight(.bold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.35)
                        .allowsTightening(true)
                    Text(GamificationStringsHelper.activeMinutes(snapshot.currentMinutes))
                        .font(compact ? .caption2 : .caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.35)
                        .allowsTightening(true)
                }
                .frame(width: dialSize * 0.72)
                .position(centre)
                .accessibilityElement(children: .combine)
                .accessibilityValue(
                    Text("\(Int((GamificationOrbitPresentation.progress(for: snapshot) * 100).rounded()))%")
                )

                ForEach(Array(GamificationEngine.levels.enumerated()), id: \.element.id) { index, level in
                    let angle = Angle.degrees(-90 + Double(index) * 60)
                    LevelOrbitNode(
                        number: index + 1,
                        level: level,
                        state: index == levelIndex ? .current : (index < levelIndex ? .unlocked : .locked),
                        tone: ProgressLevelPalette.tone(
                            levelIndex: index,
                            colorScheme: colorScheme
                        ),
                        compact: compact
                    )
                    .frame(width: nodeSize, height: nodeSize)
                    .accessibilitySortPriority(Double(100 - index))
                    .position(
                        x: centre.x + cos(CGFloat(angle.radians)) * radius,
                        y: centre.y + sin(CGFloat(angle.radians)) * radius
                    )
                }
            }
        }
    }
}

private enum OrbitNodeState {
    case current
    case unlocked
    case locked
}

private struct LevelOrbitNode: View {
    let number: Int
    let level: GamificationLevelDefinition
    let state: OrbitNodeState
    let tone: ProgressLevelTone
    let compact: Bool

    private var status: String {
        state == .locked ? GamificationStringsHelper.locked : GamificationStringsHelper.unlocked
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(state == .locked ? Color(uiColor: .tertiarySystemFill) : tone.accent)
                .overlay {
                    Circle()
                        .stroke(
                            state == .current ? tone.accent : Color.primary.opacity(0.13),
                            lineWidth: state == .current ? (compact ? 4 : 5) : 1
                        )
                        .padding(state == .current ? -4 : 0)
                }
                .shadow(
                    color: state == .current ? tone.accent.opacity(0.34) : .clear,
                    radius: state == .current ? 7 : 0
                )

            Text(String(number))
                .font(compact ? .caption : .subheadline)
                .fontWeight(.bold)
                .foregroundStyle(state == .locked ? Color.secondary : tone.onAccent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Image(systemName: state == .locked ? "lock.fill" : "checkmark")
                .font(.system(size: compact ? 7 : 8, weight: .bold))
                .foregroundStyle(state == .locked ? Color.secondary : tone.onAccent)
                .padding(compact ? 3 : 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(GamificationStringsHelper.levelName(forNameKey: level.nameKey))
        .accessibilityValue(
            "\(GamificationStringsHelper.unlockCriterion(minutes: level.thresholdMinutes)), \(status)"
        )
        .accessibilityAddTraits(state == .current ? .isSelected : [])
    }
}

private struct MilestoneConstellation: View {
    let snapshot: GamificationSnapshot
    let accent: Color
    let colorScheme: ColorScheme
    let compact: Bool

    private var unlockedIds: Set<String> {
        Set(snapshot.unlockedMilestoneIds)
    }

    var body: some View {
        GeometryReader { proxy in
            let titleHeight = proxy.size.height * 0.26
            let rowHeight = (proxy.size.height - titleHeight) / 2
            let horizontalGap: CGFloat = compact ? 12 : 18
            let nodeSize = max(
                12,
                min(
                    compact ? 36 : 42,
                    (proxy.size.width - horizontalGap * 3) / 4,
                    rowHeight * 0.86
                )
            )

            VStack(spacing: 0) {
                Text(GamificationStringsHelper.milestones)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .allowsTightening(true)
                    .frame(maxWidth: .infinity)
                    .frame(height: titleHeight)
                    .accessibilityAddTraits(.isHeader)

                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: horizontalGap) {
                        ForEach(Array(GamificationEngine.milestones[(row * 4)..<(row * 4 + 4)]), id: \.id) { milestone in
                            MilestoneNode(
                                milestone: milestone,
                                unlocked: unlockedIds.contains(milestone.id),
                                latest: snapshot.latestUnlockedMilestoneId == milestone.id,
                                accent: accent,
                                colorScheme: colorScheme,
                                compact: compact,
                                nodeSize: nodeSize
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: rowHeight)
                }
            }
        }
    }
}

private struct MilestoneNode: View {
    let milestone: GamificationMilestoneDefinition
    let unlocked: Bool
    let latest: Bool
    let accent: Color
    let colorScheme: ColorScheme
    let compact: Bool
    let nodeSize: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(unlocked ? accent : Color(uiColor: .tertiarySystemFill))
                .overlay {
                    Circle()
                        .stroke(
                            latest ? accent : Color.primary.opacity(0.12),
                            lineWidth: latest ? 3 : 1
                        )
                        .padding(latest ? -3 : 0)
                }

            Text(String(milestone.activityCount))
                .font(.system(size: compact ? 10 : 11, weight: .bold, design: .rounded))
                .foregroundStyle(
                    unlocked
                        ? ProgressLevelPalette.foreground(colorScheme: colorScheme)
                        : Color.secondary
                )
                .minimumScaleFactor(0.35)
                .allowsTightening(true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Image(systemName: unlocked ? "checkmark" : "lock.fill")
                .font(.system(size: 6, weight: .bold))
                .foregroundStyle(
                    unlocked
                        ? ProgressLevelPalette.foreground(colorScheme: colorScheme)
                        : Color.secondary
                )
                .padding(3)
        }
        .frame(width: nodeSize, height: nodeSize)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            GamificationStringsHelper.milestoneTitle(activityCount: milestone.activityCount)
        )
        .accessibilityValue(
            unlocked ? GamificationStringsHelper.unlocked : GamificationStringsHelper.locked
        )
        .accessibilityAddTraits(latest ? .isSelected : [])
    }
}

private struct ProgressLevelTone {
    let accent: Color
    let onAccent: Color
}

private enum ProgressLevelPalette {
    private static let light: [UInt32] = [
        0x475569, 0x0277B6, 0x0F766E, 0xB45309, 0xC2410C, 0x7E22CE
    ]
    private static let dark: [UInt32] = [
        0xCBD5E1, 0x29B6F6, 0x5EEAD4, 0xFBBF24, 0xFB923C, 0xD8B4FE
    ]

    static func accent(levelIndex: Int, colorScheme: ColorScheme) -> Color {
        tone(levelIndex: levelIndex, colorScheme: colorScheme).accent
    }

    static func tone(levelIndex: Int, colorScheme: ColorScheme) -> ProgressLevelTone {
        let safeIndex = min(max(levelIndex, 0), light.count - 1)
        let isDark = colorScheme == .dark
        return ProgressLevelTone(
            accent: Color(hex: isDark ? dark[safeIndex] : light[safeIndex]),
            onAccent: isDark ? BrandColor.navy900 : .white
        )
    }

    static func foreground(colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? BrandColor.navy900 : .white
    }
}
