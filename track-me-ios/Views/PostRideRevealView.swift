import SwiftUI

/// B1 — the post-ride reveal surface (iOS). A single, calm, gain-framed celebration shown once
/// after a good ride is saved; replaces the flat "Ride saved" toast. Parity with Android's
/// `PostRideRevealDialog`.
///
/// Design guardrails: bounded set only (`RevealKind`); brand accent via `.tint`/accentColor
/// (repointed to cyan by C2); Dynamic Type + VoiceOver friendly; no forced animation; dismiss
/// is the only action and fires the telemetry exactly once (on appear).
struct PostRideRevealView: View {
    let reveal: Reveal
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 84, height: 84)
                Image(systemName: symbol)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .accessibilityHidden(true)
            .padding(.top, 32)

            Text(title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Text(LocalizationHelper.localized("Nice!"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        // One clean VoiceOver announcement of the whole reveal.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(message)")
        .onAppear {
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
            let value = reveal.kind == .distancePR ? Self.formatKm(reveal.distanceMeters)
                                                   : Self.formatDuration(reveal.durationMillis)
            return LocalizationHelper.formatted("%@ — your longest ride yet.", value)
        case .milestone:
            return LocalizationHelper.localized("That's a real milestone. Keep it rolling.")
        case .standard:
            return LocalizationHelper.formatted(
                "%@ in %@. Great to have you out there.",
                Self.formatKm(reveal.distanceMeters), Self.formatDuration(reveal.durationMillis)
            )
        }
    }

    static func formatKm(_ meters: Double) -> String {
        String(format: "%.1f km", meters / 1000.0)
    }

    /// Compact "1h 20m" / "45m"; parity with Android's reveal formatting.
    static func formatDuration(_ millis: Int64) -> String {
        let totalMinutes = Int(millis / 60_000)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? String(format: "%dh %dm", hours, minutes) : String(format: "%dm", minutes)
    }
}
