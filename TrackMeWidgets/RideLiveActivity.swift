import ActivityKit
import WidgetKit
import SwiftUI

// Renders the active-ride Live Activity on the Lock Screen and in the Dynamic
// Island. Consumes the shared `RideActivityAttributes` (add that file to this
// target's membership). Views are intentionally cheap — no maps or charts — and
// the payload carries only aggregates (no coordinates).

struct RideLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RideActivityAttributes.self) { context in
            RideLockScreenView(state: context.state)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RideActivityFormat.durationView(context.state)
                        .font(.title3).bold().monospacedDigit()
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(RideActivityFormat.distance(context.state)).font(.headline)
                        Text(RideActivityFormat.speed(context.state))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    RideActivityAlertRow(
                        text: RideActivityFormat.bottomLine(context.state),
                        isAlert: context.state.alertSignal == .raised,
                        systemImage: RideActivityFormat.bottomIcon(context.state)
                    )
                }
                DynamicIslandExpandedRegion(.center) {
                    if let memberCount = RideActivityFormat.memberCountLine(context.state) {
                        RideActivityMemberCountPill(text: memberCount)
                    }
                }
            } compactLeading: {
                Image(systemName: RideActivityFormat.statusIcon(context.state))
                    .foregroundStyle(RideActivityFormat.statusTint(context.state))
            } compactTrailing: {
                RideActivityFormat.durationView(context.state)
                    .font(.caption2).monospacedDigit()
            } minimal: {
                Image(systemName: RideActivityFormat.statusIcon(context.state))
                    .foregroundStyle(RideActivityFormat.minimalStatusTint(context.state))
            }
            .keylineTint(BrandColor.primary)
        }
    }
}

private struct RideLockScreenView: View {
    let state: RideActivityAttributes.ContentState
    @ScaledMetric(relativeTo: .largeTitle) private var durationSize: CGFloat = 34

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label("TrackMe", systemImage: RideActivityFormat.statusIcon(state))
                    .font(.caption).foregroundStyle(.secondary)
                RideActivityFormat.durationView(state)
                    .font(.system(size: durationSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(RideActivityFormat.rideStatusLine(state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let alert = RideActivityFormat.alertLine(state) {
                    RideActivityAlertRow(
                        text: alert,
                        isAlert: true,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                } else if let memberCount = RideActivityFormat.memberCountLine(state) {
                    RideActivityMemberCountPill(text: memberCount)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                metric(RideActivityFormat.distance(state), caption: String(localized: "Distance"))
                metric(RideActivityFormat.speed(state), caption: String(localized: "Speed"))
            }
        }
    }

    private func metric(_ value: String, caption: String) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(value).font(.headline).monospacedDigit()
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct RideActivityAlertRow: View {
    let text: String
    let isAlert: Bool
    let systemImage: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .foregroundStyle(isAlert ? BrandColor.destructive : Color.secondary)
            // The complete user-provided name is handed to Text. SwiftUI's
            // layout truncates only at Character boundaries; never pre-truncate
            // by UTF-8/UTF-16 offsets, which can split a grapheme.
            Text(text)
                .foregroundStyle(isAlert ? Color.white : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .allowsTightening(true)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

private struct RideActivityMemberCountPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(BrandColor.primary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(BrandColor.primary.opacity(0.18), in: Capsule())
    }
}

extension RideActivityFormat {
    /// Auto-ticking duration when running; a frozen value when paused so the
    /// timer never depends on update delivery.
    @ViewBuilder
    static func durationView(_ state: RideActivityAttributes.ContentState) -> some View {
        if state.isPaused {
            Text(frozenDuration(state.pausedElapsed))
        } else {
            Text(timerInterval: state.startedAt...Date(timeIntervalSinceNow: 8 * 3600),
                 countsDown: false)
        }
    }

    static func statusIcon(_ state: RideActivityAttributes.ContentState) -> String {
        if state.isPaused { return "pause.circle.fill" }
        if state.isGpsLost { return "location.slash.fill" }
        return "record.circle"
    }

    static func statusTint(_ state: RideActivityAttributes.ContentState) -> Color {
        // Semantic, routed through the shared brand tokens (C2): paused / GPS-lost
        // are warnings (amber); actively recording is the brand action (cyan).
        if state.isPaused { return BrandColor.warning }
        if state.isGpsLost { return BrandColor.warning }
        return BrandColor.primary
    }

    static func minimalStatusTint(_ state: RideActivityAttributes.ContentState) -> Color {
        state.alertSignal == .raised ? BrandColor.destructive : statusTint(state)
    }

    static func bottomIcon(_ state: RideActivityAttributes.ContentState) -> String {
        if state.alertSignal == .raised { return "exclamationmark.triangle.fill" }
        if state.isGpsLost { return "location.slash.fill" }
        if state.isPaused { return "pause.circle.fill" }
        return "record.circle"
    }
}
