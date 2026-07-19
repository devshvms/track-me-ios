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
                    if let status = RideActivityFormat.statusLine(context.state) {
                        Label(status, systemImage: RideActivityFormat.statusIcon(context.state))
                            .font(.caption).foregroundStyle(.secondary)
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
                    .foregroundStyle(RideActivityFormat.statusTint(context.state))
            }
            .keylineTint(.green)
        }
    }
}

private struct RideLockScreenView: View {
    let state: RideActivityAttributes.ContentState

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label("TrackMe", systemImage: RideActivityFormat.statusIcon(state))
                    .font(.caption).foregroundStyle(.secondary)
                RideActivityFormat.durationView(state)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                if let status = RideActivityFormat.statusLine(state) {
                    Text(status).font(.caption).foregroundStyle(.secondary)
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

/// Shared formatting so the Lock Screen and Dynamic Island can't diverge.
enum RideActivityFormat {
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

    static func distance(_ state: RideActivityAttributes.ContentState) -> String {
        let km = state.distanceMeters / 1000
        return "\(km.formatted(.number.precision(.fractionLength(2)))) km"
    }

    static func speed(_ state: RideActivityAttributes.ContentState) -> String {
        let kmh = max(0, state.speedMps) * 3.6
        return "\(kmh.formatted(.number.precision(.fractionLength(1)))) km/h"
    }

    static func statusLine(_ state: RideActivityAttributes.ContentState) -> String? {
        if state.isPaused { return String(localized: "Paused") }
        if state.isGpsLost { return String(localized: "Searching for GPS…") }
        return String(localized: "Recording ride")
    }

    static func statusIcon(_ state: RideActivityAttributes.ContentState) -> String {
        if state.isPaused { return "pause.circle.fill" }
        if state.isGpsLost { return "location.slash.fill" }
        return "record.circle"
    }

    static func statusTint(_ state: RideActivityAttributes.ContentState) -> Color {
        if state.isPaused { return .orange }
        if state.isGpsLost { return .yellow }
        return .green
    }

    private static func frozenDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}
