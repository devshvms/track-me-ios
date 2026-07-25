import SwiftUI

/// A reusable, bounded celebration surface for earned achievements.
///
/// Callers provide only the SF Symbol. The badge owns its brand-cyan lit-sphere,
/// glow, bezel, and calm motion so future achievement surfaces cannot drift into
/// a collection of one-off celebration treatments. Ordinary rides deliberately
/// stay on the static reveal icon and do not use this view.
struct AchievementBadge: View {
    let symbol: String
    var size: CGFloat = 96

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        Group {
            if reduceMotion {
                settledBadge
            } else {
                // TimelineView is created only when Reduce Motion is disabled.
                // This keeps the ambient loop out of the view hierarchy entirely
                // for users who have asked the system to minimize motion.
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                    animatedBadge(at: context.date)
                }
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(appeared ? 1 : 0.5)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            guard !appeared else { return }
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) {
                    appeared = true
                }
            }
        }
    }

    private var settledBadge: some View {
        badge(pulse: 1, shineAngle: 0)
    }

    private func animatedBadge(at date: Date) -> some View {
        let elapsed = date.timeIntervalSinceReferenceDate
        let pulsePhase = elapsed * (2 * .pi / 2.2)
        let pulse = 0.82 + 0.18 * (0.5 + 0.5 * sin(pulsePhase))
        let shineAngle = (elapsed.truncatingRemainder(dividingBy: 3.4) / 3.4) * 360
        return badge(pulse: pulse, shineAngle: shineAngle)
    }

    private func badge(pulse: Double, shineAngle: Double) -> some View {
        ZStack {
            // Ambient glow: the pulse changes only the opacity/scale, never the
            // visual language or brand token.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [BrandColor.primary.opacity(0.42), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: size * 0.78
                    )
                )
                .frame(width: size * 1.5, height: size * 1.5)
                .scaleEffect(0.95 + (pulse - 0.82) * 0.35)
                .opacity(0.72 + (pulse - 0.82) * 1.4)

            // Lit sphere. The lighter and darker sides are derived from the
            // dynamic primary token, so light/dark mode keeps the same cyan hue.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            BrandColor.onPrimary.opacity(0.72),
                            BrandColor.primary,
                            BrandColor.primary.opacity(0.62)
                        ],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: size * 0.82
                    )
                )
                .frame(width: size, height: size)

            // Additive shine sweep contained to the disc.
            Circle()
                .fill(
                    AngularGradient(
                        colors: [
                            .clear,
                            BrandColor.onPrimary.opacity(0.3),
                            .clear,
                            .clear,
                            .clear
                        ],
                        center: .center
                    )
                )
                .frame(width: size, height: size)
                .rotationEffect(.degrees(shineAngle))
                .blendMode(.plusLighter)
                .clipShape(Circle())

            Circle()
                .stroke(BrandColor.onPrimary.opacity(0.78), lineWidth: 3)
                .frame(width: size - 3, height: size - 3)

            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(BrandColor.onPrimary)
        }
        .compositingGroup()
    }
}

#Preview("Achievement badges") {
    HStack(spacing: 20) {
        AchievementBadge(symbol: "sparkles")
        AchievementBadge(symbol: "trophy.fill", size: 84)
        AchievementBadge(symbol: "flag.checkered", size: 72)
    }
    .padding(32)
    .background(BrandColor.navy900)
}
