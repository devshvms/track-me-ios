import SwiftUI

/// Intent-first broadcast HUD displayed when the rider launches "Share Live Location" from Home.
/// Centers active viewer count, notified watchers, quick link sharing, and an encapsulated ride
/// summary strip that expands into the full ride telemetry HUD on tap.
struct LiveShareBroadcastHudView: View {
    let trackingState: TrackingState
    let distanceText: String
    let elapsedDurationText: String
    let timeSinceLastGps: TimeInterval
    let isGpsLostWarningActive: Bool
    let isOffline: Bool
    var liveSharingManager: LiveSharingManager
    let onExpandRideTelemetry: () -> Void
    let onCopyShare: () -> Void
    let onSendShare: () -> Void
    let onStopShareAndRide: () -> Void
    let onKeepRecordingRide: () -> Void

    private var remainingLabel: String? {
        guard liveSharingManager.isActive else { return nil }
        let sec = max(0, liveSharingManager.remainingSeconds)
        let hours = sec / 3600
        let mins = (sec % 3600) / 60
        let secs = sec % 60
        if hours > 0 {
            return String(format: "%dh %02dm", hours, mins)
        } else if mins > 0 {
            return String(format: "%dm %02ds", mins, secs)
        } else {
            return String(format: "%ds", secs)
        }
    }

    private var notifiedCount: Int {
        max(liveSharingManager.notifiedWatchersCount, liveSharingManager.sharedWatcherNames.count)
    }

    var body: some View {
        VStack(spacing: 8) {
            statusPills

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "eye.fill")
                        .font(.title3)
                        .foregroundStyle(liveSharingManager.activeViewers > 0 ? BrandColor.cyanBright : .secondary)

                    Text(
                        liveSharingManager.activeViewers > 0
                            ? LocalizationHelper.formatted("%@ watching", String(liveSharingManager.activeViewers))
                            : LocalizationHelper.localized("No viewers yet — link active")
                    )
                    .font(.headline.bold())
                    .lineLimit(2)

                    Spacer(minLength: 0)
                }

                if notifiedCount > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(
                            LocalizationHelper.formatted("Notified %@ trusted watchers", String(notifiedCount)),
                            systemImage: "bell.badge.fill"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(BrandColor.primary)

                        if !liveSharingManager.sharedWatcherNames.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(liveSharingManager.sharedWatcherNames, id: \.self) { name in
                                        Text(name)
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                                    }
                                }
                            }
                        }
                    }
                }

                Button(action: onExpandRideTelemetry) {
                    HStack(spacing: 10) {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(BrandColor.primary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(distanceText) · \(elapsedDurationText)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(LocalizationHelper.localized("Tap to view full ride telemetry"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                }
                .buttonStyle(.plain)

                Divider()

                HStack(spacing: 10) {
                    Button(action: onCopyShare) {
                        Label(LocalizationHelper.localized("Copy link"), systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(liveSharingManager.shareLink == nil)

                    Button(action: onSendShare) {
                        Label(LocalizationHelper.localized("Share link"), systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(liveSharingManager.shareLink == nil)
                }

                HStack(spacing: 10) {
                    Button(role: .destructive, action: onStopShareAndRide) {
                        Label(LocalizationHelper.localized("Stop & Save"), systemImage: "stop.fill")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 40)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BrandColor.destructive)

                    Button(action: onKeepRecordingRide) {
                        Text(LocalizationHelper.localized("Keep Recording Ride"))
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .buttonStyle(.borderless)
                    .frame(minHeight: 40)
                }
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 8)
        }
    }

    private var statusPills: some View {
        HStack(spacing: 6) {
            broadcastPill(
                title: LocalizationHelper.localized("LIVE SHARING"),
                systemImage: "antenna.radiowaves.left.and.right",
                background: BrandColor.cyanBright,
                foreground: BrandColor.navy900
            )

            if let remainingLabel {
                broadcastPill(
                    title: remainingLabel,
                    systemImage: "clock.fill",
                    background: Color(uiColor: .secondarySystemGroupedBackground),
                    foreground: .primary
                )
            }

            if isOffline {
                broadcastPill(
                    title: LocalizationHelper.localized("Offline shield"),
                    systemImage: "shield.checkered",
                    background: BrandColor.success,
                    foreground: .white
                )
            }

            if trackingState == .storageLow || isGpsLostWarningActive {
                let sec = max(1, Int(timeSinceLastGps))
                let title = trackingState == .storageLow
                    ? LocalizationHelper.localized("Storage almost full")
                    : LocalizationHelper.formatted("No GPS %@", "\(sec)s")
                broadcastPill(
                    title: title,
                    systemImage: "exclamationmark.triangle.fill",
                    background: BrandColor.destructive,
                    foreground: .white
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func broadcastPill(
        title: String,
        systemImage: String,
        background: Color,
        foreground: Color
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.bold())
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(background, in: Capsule())
            .shadow(color: .black.opacity(0.14), radius: 3, y: 2)
    }
}
