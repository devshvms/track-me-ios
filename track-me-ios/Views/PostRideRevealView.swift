import SwiftUI

/// B1 — the post-ride reveal surface (iOS). A single, calm, gain-framed celebration shown once
/// after a good ride is saved; replaces the flat "Ride saved" toast. Parity with Android's
/// `PostRideRevealDialog`.
///
/// Design guardrails: bounded set only (`RevealKind`); brand accent via `.tint`/accentColor
/// (repointed to cyan by C2); Dynamic Type + VoiceOver friendly; no forced animation; dismiss
/// is the only in-view action; telemetry fires exactly once per unique reveal (`.task(id:)`),
/// and any dismissal (button or swipe) acknowledges the durable one-shot via the sheet's onDismiss.
struct PostRideRevealView: View {
    let reveal: Reveal
    let onDismiss: () -> Void
    @ObservedObject private var unitSettings = UnitSettings.shared

    var body: some View {
        VStack(spacing: 14) {
            Group {
                if reveal.kind == .standard {
                    // Routine rides keep the calm, static treatment. The animated
                    // badge is reserved for an earned outcome only.
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.15))
                            .frame(width: 84, height: 84)
                        Image(systemName: symbol)
                            .font(.system(size: 40, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                } else {
                    AchievementBadge(symbol: symbol)
                }
            }
            .accessibilityHidden(true)
            .padding(.top, 18)

            Text(title)
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            Button(action: onDismiss) {
                Text(LocalizationHelper.localized("Nice!"))
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 96, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity)
        .presentationDetents([.height(360), .medium])
        .presentationBackground(.ultraThinMaterial)
        .presentationCornerRadius(28)
        .presentationDragIndicator(.visible)
        // One clean VoiceOver announcement of the whole reveal.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(message)")
        // Fire `post_ride_reveal_shown` exactly once per unique reveal, not once per appearance.
        // `.task(id:)` runs once per distinct id for the view's lifetime and re-runs only when the
        // id changes — the SwiftUI analogue of Android's `LaunchedEffect(reveal.rideId)`. Guards
        // against a within-session re-appearance (e.g. a transient system alert covering the sheet)
        // double-counting the B1 activation-funnel metric.
        .task(id: reveal.rideId) {
            TelemetryManager.shared.trackPostRideRevealShown(revealType: reveal.revealType)
        }
    }

    private var symbol: String {
        switch reveal.kind {
        case .firstRide: return "sparkles"
        case .distancePR, .durationPR: return "trophy.fill"
        case .milestone: return "flag.checkered"
        case .standard: return "checkmark.circle.fill"
        }
    }

    private var title: String {
        switch reveal.kind {
        case .firstRide: return LocalizationHelper.localized("First ride saved!")
        case .distancePR: return LocalizationHelper.localized("New distance record!")
        case .durationPR: return LocalizationHelper.localized("New time record!")
        case .milestone:
            return LocalizationHelper.formatted("%lld rides!", reveal.milestoneRideCount ?? reveal.totalRides)
        case .standard: return LocalizationHelper.localized("Ride saved")
        }
    }

    private var message: String {
        switch reveal.kind {
        case .firstRide:
            return LocalizationHelper.localized("Welcome aboard. Every journey starts with one — nicely done.")
        case .distancePR, .durationPR:
            let value = reveal.kind == .distancePR ? UnitFormatter.distance(meters: reveal.distanceMeters, unit: unitSettings.unit, decimals: 1)
                                                   : Self.formatDuration(reveal.durationMillis)
            return LocalizationHelper.formatted("%@ — your longest ride yet.", value)
        case .milestone:
            return LocalizationHelper.localized("That's a real milestone. Keep it rolling.")
        case .standard:
            return LocalizationHelper.formatted(
                "%@ in %@. Great to have you out there.",
                UnitFormatter.distance(meters: reveal.distanceMeters, unit: unitSettings.unit, decimals: 1), Self.formatDuration(reveal.durationMillis)
            )
        }
    }

    /// Compact "1h 20m" / "45m"; parity with Android's reveal formatting.
    static func formatDuration(_ millis: Int64) -> String {
        let totalMinutes = Int(millis / 60_000)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? String(format: "%dh %dm", hours, minutes) : String(format: "%dm", minutes)
    }
}
