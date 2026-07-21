import SwiftUI

/// B2 weekly recap card (iOS) with the B3 streak line. Parity with Android's WeeklyRecapDialog.
/// STRICTLY gain-framed: only appears when there is something to celebrate (rides > 0) and never
/// shows a loss/at-risk/comparison message. Accent-tinted (C2 repoints to cyan); Dynamic Type +
/// VoiceOver friendly. Emits weekly_recap_shown exactly once on appear.
struct WeeklyRecapView: View {
    let recap: WeeklyRecap
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text(LocalizationHelper.localized("Your week in review"))
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .padding(.top, 32)

            VStack(spacing: 12) {
                statRow(LocalizationHelper.localized("Rides"), "\(recap.rideCount)")
                statRow(LocalizationHelper.localized("Distance"),
                        String(format: "%.1f km", recap.distanceMeters / 1000.0))
            }
            .padding(.horizontal, 28)

            if let streak = streakLine {
                HStack(spacing: 8) {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(Color.accentColor)
                    Text(streak).font(.body.weight(.medium))
                }
                .padding(.top, 4)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(streak)
            }

            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Text(LocalizationHelper.localized("Nice week!"))
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
        .onAppear {
            TelemetryManager.shared.trackWeeklyRecapShown(
                weekKey: recap.weekKey, rideCount: recap.rideCount,
                distanceKm: recap.distanceMeters / 1000.0)
        }
    }

    private var streakLine: String? {
        if recap.streakWeeks >= 2 {
            return LocalizationHelper.formatted("%lld weeks active in a row", recap.streakWeeks)
        } else if recap.streakWeeks == 1 {
            return LocalizationHelper.localized("You stayed active this week")
        }
        return nil
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.title3.weight(.semibold))
        }
    }
}
