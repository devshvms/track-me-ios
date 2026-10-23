import SwiftUI
import SwiftData
import CoreLocation

/// B1 — the post-ride reveal surface (iOS). A celebratory summary sheet shown once
/// after a good ride is saved; replaces the flat "Ride saved" toast. Overhauled for
/// v1.9.0 (TASK-338) with:
///  - Auto-rendered Route Card thumbnail preview
///  - Key stats strip (Distance, Duration, Avg Speed)
///  - Primary "Share Trip Card / Video" action
///  - Secondary "View Trip Details" navigation action
///  - "Done" dismiss action
struct PostRideRevealView: View {
    let reveal: Reveal
    var onDismiss: () -> Void
    var onShareCard: () -> Void = {}
    var onViewDetails: () -> Void = {}

    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var unitSettings = UnitSettings.shared

    @State private var ridePolyline: String?
    @State private var pointCount: Int = 0

    var body: some View {
        VStack(spacing: 16) {
            // Header: Badge or Calm Icon
            Group {
                if reveal.kind == .standard {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.15))
                            .frame(width: 72, height: 72)
                        Image(systemName: symbol)
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                } else {
                    AchievementBadge(symbol: symbol)
                }
            }
            .accessibilityHidden(true)
            .padding(.top, 16)

            VStack(spacing: 4) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            // Route Card Thumbnail Preview
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(uiColor: .secondarySystemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )

                if pointCount >= 2, let polyline = ridePolyline, !polyline.isEmpty {
                    RouteThumbnail(
                        routePolyline: polyline,
                        pointCount: pointCount,
                        distanceMeters: reveal.distanceMeters
                    )
                    .padding(8)
                } else {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.5))
                }
            }
            .frame(height: 125)
            .padding(.horizontal, 20)

            // Key Stats Strip
            HStack(spacing: 0) {
                statColumn(
                    title: LocalizationHelper.localized("Distance"),
                    value: UnitFormatter.distance(meters: reveal.distanceMeters, unit: unitSettings.unit, decimals: 1)
                )
                statColumn(
                    title: LocalizationHelper.localized("Duration"),
                    value: Self.formatDuration(reveal.durationMillis)
                )
                let avgSpeedMps = reveal.durationMillis > 0 ? (reveal.distanceMeters / (Double(reveal.durationMillis) / 1000.0)) : 0.0
                statColumn(
                    title: LocalizationHelper.localized("Avg Speed"),
                    value: UnitFormatter.speed(mps: avgSpeedMps, unit: unitSettings.unit)
                )
            }
            .padding(.horizontal, 20)

            // Actions: Primary Share Button
            Button(action: onShareCard) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.up.fill")
                        .font(.subheadline)
                    Text(LocalizationHelper.localized("Share Trip Card / Video"))
                        .font(.subheadline.weight(.bold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Color.accentColor)
                .foregroundColor(.black)
                .cornerRadius(14)
            }
            .padding(.horizontal, 20)

            // Secondary Buttons: View Details & Done
            HStack {
                Button(action: onViewDetails) {
                    Text(LocalizationHelper.localized("View Trip Details"))
                        .font(.subheadline.weight(.medium))
                }
                Spacer()
                Button(action: onDismiss) {
                    Text(LocalizationHelper.localized("Done"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
        .presentationDetents([.height(520), .large])
        .presentationBackground(.ultraThinMaterial)
        .presentationCornerRadius(28)
        .presentationDragIndicator(.visible)
        // One clean VoiceOver announcement of the whole reveal.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(message)")
        .task(id: reveal.rideId) {
            TelemetryManager.shared.trackPostRideRevealShown(revealType: reveal.revealType)
            if let uuid = UUID(uuidString: reveal.rideId) {
                var descriptor = FetchDescriptor<Ride>(predicate: #Predicate { $0.id == uuid })
                descriptor.fetchLimit = 1
                if let r = try? modelContext.fetch(descriptor).first {
                    ridePolyline = r.routePolyline
                    pointCount = r.points?.count ?? r.pointCount ?? 0
                }
            }
        }
    }

    @ViewBuilder
    private func statColumn(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline.weight(.bold))
                .foregroundColor(.primary)
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
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
