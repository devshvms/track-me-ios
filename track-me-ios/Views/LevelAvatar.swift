import SwiftUI

/// TASK-277: a rider's level, worn on their own avatar.
///
/// An energised ring in the level's accent, and the level number in the corner. The ring is the
/// reward made visible in the one place a person looks at themselves; the number is there because a
/// ring alone is a colour, and a colour alone is not a fact anyone can read out.
///
/// **This is earned, not bought.** A supporter or "pro" treatment was considered and is not built:
/// Apple does not permit IAP for collecting donations, but giving a donor a visible badge makes it a
/// digital good that requires IAP, and the two rules together turn a contribution page back into the
/// paywall `LEVEL-THEME-01` deliberately removed. If that is ever decided differently, it is a
/// second trigger on this same view rather than a second view.
///
/// **Shown signed out too.** Levels derive from local rides, which need no account and work offline
/// — the signed-out card's own subtitle says the ride history is local only. Gating an earned,
/// offline fact behind sign-in would invent a relationship the product does not have.
///
/// **Own avatar only.** Putting a level on other riders' markers would mean extending the encrypted
/// roster envelope, re-declaring shared data, and letting everyone in a group read everyone's rank —
/// the soft leaderboard `GAMIFICATION.md` §9 rules out. That needs a product decision, not a view.
struct LevelAvatar<Avatar: View>: View {
    let levelIndex: Int
    var diameter: CGFloat = 100
    @ViewBuilder var avatar: () -> Avatar

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var energy: CGFloat = 0

    private var isDark: Bool { colorScheme == .dark }
    private var accent: Color { GamificationPalette.accent(levelIndex, dark: isDark) }
    private var ringWidth: CGFloat { diameter * 0.055 }
    private var glowReach: CGFloat { diameter * 0.16 }

    private var level: GamificationLevelDefinition? {
        GamificationEngine.levels.indices.contains(levelIndex)
            ? GamificationEngine.levels[levelIndex] : nil
    }

    var body: some View {
        ZStack {
            // The glow breathes outward from the ring rather than the ring itself changing size:
            // a ring that grows and shrinks drags the avatar's edge with it and reads as wobble.
            Circle()
                .stroke(accent.opacity(0.10 + 0.22 * Double(energy)), lineWidth: glowReach)
                .frame(width: diameter + glowReach, height: diameter + glowReach)
                .blur(radius: glowReach * 0.55)
                .allowsHitTesting(false)

            Circle()
                .stroke(accent.opacity(0.75 + 0.25 * Double(energy)), lineWidth: ringWidth)
                .frame(width: diameter + ringWidth, height: diameter + ringWidth)

            avatar()
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())

            if level != nil {
                Text("\(levelIndex + 1)")
                    .font(.system(size: diameter * 0.15, weight: .bold))
                    .foregroundStyle(GamificationPalette.onAccent(dark: isDark))
                    .frame(width: diameter * 0.30, height: diameter * 0.30)
                    .background(Circle().fill(accent))
                    .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: diameter * 0.022))
                    // Pulled inside the ring so the badge sits on the avatar's edge rather than
                    // floating clear of it.
                    .offset(x: diameter * 0.34, y: diameter * 0.34)
            }
        }
        .frame(width: diameter + glowReach * 2, height: diameter + glowReach * 2)
        // One label for the whole assembly. A screen reader announcing a ring, a photo and a number
        // as three things would be three ways of saying one.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .onAppear {
            guard !reduceMotion else {
                // Settled rather than animating and being ignored.
                energy = 0.5
                return
            }
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                energy = 1
            }
        }
    }

    private var accessibilityText: String {
        guard let level else { return GamificationStringsHelper.myProgress }
        return "\(GamificationStringsHelper.levelName(forNameKey: level.nameKey)), "
            + "\(GamificationStringsHelper.levels) \(levelIndex + 1)"
    }
}
