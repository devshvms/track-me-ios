import SwiftUI

/// TASK-276: My Progress as a route rather than a dial.
///
/// The radial version encoded progress twice — an arc for progress *within* the level and a ring of
/// six nodes for progress *across* levels — both circular, concentric, and left to the eye to
/// reconcile. A trail collapses that to one reading: where the marker sits is how far you are.
///
/// Two rules shape everything below, and they are the same two the Android screen states.
///
/// **Nothing the rider needs is behind a gesture.** The block under the trail permanently states
/// where they are and what the next level costs. Tapping a waypoint is *supplementary* detail about
/// a level they did not ask about, which is what keeps this compatible with `GAMIFICATION.md`
/// §2.1's ban on gesture-only disclosure.
///
/// **The page does not scroll.** Regions are proportional and the trail shrinks to fit, so landscape
/// and split-screen shorten the climb instead of pushing the milestones off the bottom.
struct GamificationCollectionScreen: View {
    let snapshot: GamificationSnapshot
    var achievements: [GamificationLedger.LevelAchievement] = []
    var imperial: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected: Int?
    @State private var drawn: CGFloat = 0
    @State private var bloom: CGFloat = 0
    @State private var dismissTask: Task<Void, Never>?

    private var isDark: Bool { colorScheme == .dark }
    private var levelIndex: Int { GamificationTrail.levelIndex(for: snapshot) }
    private var accent: Color { GamificationPalette.accent(levelIndex, dark: isDark) }

    var body: some View {
        GeometryReader { proxy in
            let landscape = proxy.size.width > proxy.size.height
            if landscape {
                HStack(spacing: 12) {
                    trail.frame(maxWidth: .infinity, maxHeight: .infinity)
                    VStack(spacing: 12) {
                        hint
                        readout
                        milestoneRail
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 12)
            } else {
                VStack(spacing: 0) {
                    trail.frame(maxWidth: .infinity, maxHeight: .infinity)
                    hint
                    readout.padding(.top, 4)
                    milestoneRail.padding(.top, 12)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
        }
        .navigationTitle(GamificationStringsHelper.myProgress)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // One entry sequence, played once, then still. §2.1 bans *ambient* animation, not a
            // response. Under Reduce Motion it lands settled rather than animating and being ignored.
            let target = GamificationTrail.markerFraction(snapshot)
            if reduceMotion {
                drawn = target
            } else {
                withAnimation(.easeOut(duration: 0.9)) { drawn = target }
            }
        }
    }

    // MARK: - Trail

    private var trail: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / GamificationTrail.width,
                            proxy.size.height / GamificationTrail.height)
            let board = CGSize(width: GamificationTrail.width * scale,
                               height: GamificationTrail.height * scale)
            ZStack(alignment: .topLeading) {
                // Touch-aware bloom, behind the trail: a wash of the tapped level's colour
                // spreading from the point that was touched, then gone.
                if let selected, bloom > 0.01 {
                    let origin = GamificationTrail.nodes(snapshot)[selected].position
                    let reach = (70 + 250 * bloom) * scale
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    GamificationPalette.accent(selected, dark: isDark)
                                        .opacity(bloomAlpha),
                                    .clear,
                                ],
                                center: .center, startRadius: 0, endRadius: reach
                            )
                        )
                        .frame(width: reach * 2, height: reach * 2)
                        .position(x: origin.x * scale, y: origin.y * scale)
                        .allowsHitTesting(false)
                }

                trailShape(fraction: 1)
                    .stroke(Color(.separator),
                            style: StrokeStyle(lineWidth: 5 * scale, lineCap: .round, dash: [1 * scale, 11 * scale]))
                trailShape(fraction: drawn)
                    .stroke(accent, style: StrokeStyle(lineWidth: 5 * scale, lineCap: .round))

                ForEach(GamificationTrail.nodes(snapshot).filter { $0.state != .current }, id: \.levelIndex) { node in
                    levelNode(node, scale: scale)
                }
                riderMarker(scale: scale)

                if let selected {
                    levelCard(index: selected, scale: scale, boardWidth: board.width)
                }
            }
            .frame(width: board.width, height: board.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { dismiss() }
        }
    }

    /// The trail as a drawable path, trimmed to `fraction` of its length. Built by walking the same
    /// sampled table the geometry uses, so what is drawn and what is measured cannot disagree.
    private func trailShape(fraction: CGFloat) -> Path {
        Path { path in
            let scaleFactor = CGFloat(1)
            path.move(to: GamificationTrail.point(at: 0).applying(.init(scaleX: scaleFactor, y: scaleFactor)))
            guard fraction > 0 else { return }
            let steps = 220
            for step in 1...steps {
                path.addLine(to: GamificationTrail.point(at: fraction * CGFloat(step) / CGFloat(steps)))
            }
        }
        .applying(.identity)
    }

    private var bloomAlpha: Double {
        let peak: CGFloat = 0.22, maxAlpha: Double = 0.5
        return bloom <= peak
            ? maxAlpha * Double(bloom / peak)
            : maxAlpha * Double(1 - (bloom - peak) / (1 - peak))
    }

    private func levelNode(_ node: GamificationTrail.Node, scale: CGFloat) -> some View {
        let passed = node.state == .passed
        let size = min(max(26 * scale, 20), 34)
        let nodeAccent = GamificationPalette.accent(node.levelIndex, dark: isDark)
        let level = GamificationEngine.levels[node.levelIndex]
        return Circle()
            .fill(passed ? nodeAccent : Color(.systemBackground))
            .overlay(
                Circle().strokeBorder(
                    selected == node.levelIndex ? nodeAccent : Color(.separator),
                    lineWidth: selected == node.levelIndex ? 2 : 1.5
                )
            )
            .overlay(
                // Centred, so a circular surface cannot clip it the way the radial version's
                // BottomEnd lock and check icons were clipped.
                Text("\(node.levelIndex + 1)")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(passed ? GamificationPalette.onAccent(dark: isDark) : Color.secondary)
            )
            .frame(width: size, height: size)
            .position(x: node.position.x * scale, y: node.position.y * scale)
            .contentShape(Circle())
            .onTapGesture { select(node.levelIndex) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "\(GamificationStringsHelper.levelName(forNameKey: level.nameKey)), "
                + GamificationStringsHelper.unlockCriterion(minutes: level.thresholdMinutes)
                + ", " + (passed ? GamificationStringsHelper.unlocked : GamificationStringsHelper.locked)
            )
            .accessibilitySortPriority(Double(GamificationEngine.levels.count - node.levelIndex))
    }

    /// The rider. Deliberately the largest and most detailed thing on the trail: in the radial
    /// version every node wore its own level's colour, so an already-passed level could out-shout
    /// the current one and the eye landed on the wrong dot.
    private func riderMarker(scale: CGFloat) -> some View {
        let size = min(max(38 * scale, 30), 48)
        let position = GamificationTrail.markerPosition(snapshot)
        return Circle()
            .fill(accent)
            .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 3))
            .overlay(
                Text("\(levelIndex + 1)")
                    .font(.system(size: size * 0.36, weight: .bold))
                    .foregroundStyle(GamificationPalette.onAccent(dark: isDark))
            )
            .frame(width: size, height: size)
            .position(x: position.x * scale, y: position.y * scale)
            .contentShape(Circle())
            .onTapGesture { select(levelIndex) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                LocalizationHelper.localized("You are here") + ", "
                + GamificationStringsHelper.levelName(forNameKey: snapshot.currentLevelNameKey) + ", "
                + GamificationStringsHelper.activeMinutes(snapshot.currentMinutes)
            )
            .accessibilitySortPriority(Double(GamificationEngine.levels.count + 1))
    }

    /// Detail for a tapped level, anchored in the column the serpentine path leaves empty.
    ///
    /// Split into small sub-views deliberately: SwiftUI's type checker gave up on the single
    /// expression this started as, which is a real constraint on how much can live in one `body`.
    private func levelCard(index: Int, scale: CGFloat, boardWidth: CGFloat) -> some View {
        let node = GamificationTrail.nodes(snapshot)[index]
        let cardWidth: CGFloat = max(boardWidth * 0.58, 150)
        let rawX: CGFloat = node.cardOnRight
            ? node.position.x * scale + 18
            : node.position.x * scale - 18 - cardWidth
        let clampedX: CGFloat = min(max(rawX, 0), max(boardWidth - cardWidth, 0))
        let y: CGFloat = max(node.position.y * scale - 46, 0) + 40
        return cardBody(index: index)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(width: cardWidth, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
            .position(x: clampedX + cardWidth / 2, y: y)
    }

    @ViewBuilder
    private func cardBody(index: Int) -> some View {
        let level = GamificationEngine.levels[index]
        let achievement: GamificationLedger.LevelAchievement? =
            achievements.indices.contains(index) ? achievements[index] : nil
        VStack(alignment: .leading, spacing: 3) {
            Text(GamificationStringsHelper.levelName(forNameKey: level.nameKey))
                .font(.subheadline.weight(.semibold))
            Text(metaLine(index: index, level: level, achievement: achievement))
                .font(.caption2)
                .foregroundStyle(.secondary)
            // Only for levels already reached: an unreached level has no history to describe, and
            // inventing a projection would be a forecast, not a fact.
            if let achievement, achievement.achievedAtEpochMillis != nil {
                ForEach(achievement.personaSplit, id: \.personaRaw) { part in
                    personaRow(part)
                }
            }
        }
    }

    @ViewBuilder
    private func personaRow(_ part: GamificationLedger.PersonaContribution) -> some View {
        let name = RidePersona(rawValue: part.personaRaw)?.displayName ?? part.personaRaw
        let distance = UnitFormatter.distance(meters: part.distanceMeters,
                                              unit: imperial ? .imperial : .metric, decimals: 1)
        let time = Self.duration(part.activeDurationMillis)
        VStack(alignment: .leading, spacing: 0) {
            Text(name).font(.caption2.weight(.semibold))
            Text("\(distance) · \(time)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private func metaLine(index: Int, level: GamificationLevelDefinition,
                          achievement: GamificationLedger.LevelAchievement?) -> String {
        if let millis = achievement?.achievedAtEpochMillis {
            let date = Date(timeIntervalSince1970: Double(millis) / 1000)
            let text = date.formatted(date: .abbreviated, time: .omitted)
            return index == 0
                ? LocalizationHelper.formatted("Joined %@", text)
                : LocalizationHelper.formatted("Reached %@", text)
        }
        let toGo = max(0, level.thresholdMinutes - snapshot.currentMinutes)
        return LocalizationHelper.formatted("%@ min · %@ to go",
                                            String(level.thresholdMinutes), String(toGo))
    }

    /// "128m" beside "93.4 km" reads as 128 metres. It meant 128 minutes.
    static func duration(_ millis: Int64) -> String {
        let totalMinutes = max(0, millis / 60_000)
        let hours = totalMinutes / 60, minutes = totalMinutes % 60
        if hours <= 0 { return "\(totalMinutes) min" }
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }

    // MARK: - Permanent readout

    private var hint: some View {
        Text(selected == nil ? LocalizationHelper.localized("Tap a level for details") : " ")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 6)
    }

    private var readout: some View {
        let next = GamificationEngine.levels.indices.contains(levelIndex + 1)
            ? GamificationEngine.levels[levelIndex + 1] : nil
        return VStack(alignment: .leading, spacing: 2) {
            Text(GamificationStringsHelper.levelName(forNameKey: snapshot.currentLevelNameKey))
                .font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Text(GamificationStringsHelper.activeMinutes(snapshot.currentMinutes))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let next {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(LocalizationHelper.localized("Next")) · "
                         + GamificationStringsHelper.levelName(forNameKey: next.nameKey))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    // The figure is tinted with the accent of the level being chased, so the number
                    // and the colour it buys are the same fact.
                    (Text(String(max(0, next.thresholdMinutes - snapshot.currentMinutes)))
                        .foregroundColor(GamificationPalette.accent(levelIndex + 1, dark: isDark))
                        .fontWeight(.bold)
                     + Text(" " + LocalizationHelper.localized("min of tracking to go")))
                        .font(.callout.weight(.semibold))
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Milestones count *activities*; the trail counts *minutes*. Two axes, so two instruments —
    /// putting both on one path would imply they advance together, and they do not.
    private var milestoneRail: some View {
        VStack(spacing: 9) {
            HStack {
                Text(LocalizationHelper.localized("Activities"))
                    .font(.caption2).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text(LocalizationHelper.formatted("%@ recorded", String(snapshot.currentActivityCount)))
                    .font(.caption.weight(.semibold))
            }
            HStack(spacing: 5) {
                ForEach(GamificationEngine.milestones, id: \.id) { milestone in
                    let unlocked = snapshot.unlockedMilestoneIds.contains(milestone.id)
                    let isNext = !unlocked && GamificationEngine.milestones
                        .first { !snapshot.unlockedMilestoneIds.contains($0.id) }?.id == milestone.id
                    VStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(unlocked ? accent : (isNext ? accent.opacity(0.32) : Color(.separator)))
                            .frame(height: 5)
                        Text(milestone.activityCount >= 1_000
                             ? "\(milestone.activityCount / 1_000)K" : "\(milestone.activityCount)")
                            .font(.system(size: 9))
                            .foregroundStyle(unlocked ? Color.primary : Color.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        GamificationStringsHelper.milestoneTitle(activityCount: milestone.activityCount)
                        + ", " + (unlocked ? GamificationStringsHelper.unlocked : GamificationStringsHelper.locked)
                    )
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Selection

    private func select(_ index: Int) {
        selected = index
        dismissTask?.cancel()
        if reduceMotion {
            bloom = 0
        } else {
            bloom = 0
            withAnimation(.timingCurve(0.2, 0.7, 0.3, 1, duration: 1.5)) { bloom = 1 }
        }
        // The card dismisses itself. A rider who taps a level to satisfy a passing curiosity should
        // not have to tidy up after it, and leaving it open would obscure the trail it describes.
        dismissTask = Task {
            try? await Task.sleep(nanoseconds: 4_200_000_000)
            if !Task.isCancelled { await MainActor.run { dismiss() } }
        }
    }

    private func dismiss() {
        dismissTask?.cancel()
        selected = nil
        bloom = 0
    }
}
