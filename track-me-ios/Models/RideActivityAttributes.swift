import ActivityKit
import Foundation

/// The only group-status signal allowed into the Live Activity payload. It is
/// intentionally an aggregate presentation event: no member identifier, group
/// identifier, or positional data crosses the ActivityKit boundary.
nonisolated enum RideActivityAlertSignal: String, Codable, Hashable {
    case none = "NONE"
    case raised = "ALERT_RAISED"
    case resolved = "ALERT_RESOLVED"
}

/// Shared Live Activity contract between the app (which drives updates) and the
/// `TrackMeWidgets` extension (which renders the Lock Screen / Dynamic Island).
///
/// IMPORTANT: this file must be a member of BOTH the `track-me-ios` app target
/// and the `TrackMeWidgets` extension target.
///
/// Privacy/budget note: the payload carries only aggregates — never coordinates.
struct RideActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// Anchor for the auto-ticking timer. Recomputed as `now - elapsed` on
        /// each update so paused time is excluded and the timer never drifts.
        var startedAt: Date
        var distanceMeters: Double
        var speedMps: Double
        var isPaused: Bool
        var isGpsLost: Bool
        /// Elapsed seconds captured at pause time, for the frozen paused display.
        var pausedElapsed: TimeInterval

        /// Aggregate group presentation state. A zero count means the rider is
        /// not in a group. Names and status codes are present only while an
        /// alert is raised; coordinates are never part of this contract.
        var groupMemberCount: Int
        var alertSignal: RideActivityAlertSignal
        var alertMemberName: String
        var alertStatusCode: String

        init(
            startedAt: Date,
            distanceMeters: Double,
            speedMps: Double,
            isPaused: Bool,
            isGpsLost: Bool,
            pausedElapsed: TimeInterval,
            groupMemberCount: Int = 0,
            alertSignal: RideActivityAlertSignal = .none,
            alertMemberName: String = "",
            alertStatusCode: String = ""
        ) {
            self.startedAt = startedAt
            self.distanceMeters = distanceMeters
            self.speedMps = speedMps
            self.isPaused = isPaused
            self.isGpsLost = isGpsLost
            self.pausedElapsed = pausedElapsed
            self.groupMemberCount = max(0, groupMemberCount)
            self.alertSignal = alertSignal
            self.alertMemberName = alertMemberName
            self.alertStatusCode = alertStatusCode
        }

        private enum CodingKeys: String, CodingKey {
            case startedAt, distanceMeters, speedMps, isPaused, isGpsLost, pausedElapsed
            case groupMemberCount, alertSignal, alertMemberName, alertStatusCode
        }

        /// Explicit additive decoding is required for an activity created by
        /// the previous app version and decoded after an in-place app update.
        /// Stored-property defaults alone are not used by Codable synthesis.
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            startedAt = try values.decode(Date.self, forKey: .startedAt)
            distanceMeters = try values.decode(Double.self, forKey: .distanceMeters)
            speedMps = try values.decode(Double.self, forKey: .speedMps)
            isPaused = try values.decode(Bool.self, forKey: .isPaused)
            isGpsLost = try values.decode(Bool.self, forKey: .isGpsLost)
            pausedElapsed = try values.decode(TimeInterval.self, forKey: .pausedElapsed)
            groupMemberCount = max(
                0,
                try values.decodeIfPresent(Int.self, forKey: .groupMemberCount) ?? 0
            )
            alertSignal = try values.decodeIfPresent(
                RideActivityAlertSignal.self,
                forKey: .alertSignal
            ) ?? .none
            alertMemberName = try values.decodeIfPresent(
                String.self,
                forKey: .alertMemberName
            ) ?? ""
            alertStatusCode = try values.decodeIfPresent(
                String.self,
                forKey: .alertStatusCode
            ) ?? ""
        }
    }

    var rideId: String
}

nonisolated enum RideActivityBottomContent: Equatable {
    case alert(String)
    case gpsLost
    case paused
    case recording
}

/// Shared formatting so the Lock Screen and every Dynamic Island presentation
/// cannot diverge. SwiftUI-only view helpers extend this same enum in the widget.
nonisolated enum RideActivityFormat {
    static func distance(_ state: RideActivityAttributes.ContentState) -> String {
        let km = state.distanceMeters / 1000
        return "\(km.formatted(.number.precision(.fractionLength(2)))) km"
    }

    static func speed(_ state: RideActivityAttributes.ContentState) -> String {
        let kmh = max(0, state.speedMps) * 3.6
        return "\(kmh.formatted(.number.precision(.fractionLength(1)))) km/h"
    }

    /// Alert -> GPS lost -> paused -> recording, decided once for the expanded
    /// bottom region. Other views consume this result rather than reimplementing
    /// precedence locally.
    static func bottomContent(
        _ state: RideActivityAttributes.ContentState
    ) -> RideActivityBottomContent {
        if let alert = alertLine(state) { return .alert(alert) }
        if state.isGpsLost { return .gpsLost }
        if state.isPaused { return .paused }
        return .recording
    }

    static func bottomLine(_ state: RideActivityAttributes.ContentState) -> String {
        switch bottomContent(state) {
        case .alert(let line): line
        case .gpsLost: String(localized: "Searching for GPS…")
        case .paused: String(localized: "Paused")
        case .recording: String(localized: "Recording ride")
        }
    }

    static func rideStatusLine(_ state: RideActivityAttributes.ContentState) -> String {
        if state.isPaused { return String(localized: "Paused") }
        if state.isGpsLost { return String(localized: "Searching for GPS…") }
        return String(localized: "Recording ride")
    }

    static func alertLine(_ state: RideActivityAttributes.ContentState) -> String? {
        guard state.alertSignal == .raised,
              !state.alertMemberName.isEmpty else { return nil }
        return String.localizedStringWithFormat(
            String(localized: "%@ — %@"),
            state.alertMemberName,
            alertStatusLabel(code: state.alertStatusCode)
        )
    }

    static func memberCountLine(_ state: RideActivityAttributes.ContentState) -> String? {
        guard state.groupMemberCount > 0,
              state.alertSignal != .raised else { return nil }
        return String.localizedStringWithFormat(
            String(localized: "%d riding"),
            state.groupMemberCount
        )
    }

    static func alertStatusLabel(code: String) -> String {
        switch code.prefix(4) {
        case "1GNH": String(localized: "Need help")
        case "1GCR": String(localized: "Crashed")
        default: String(localized: "Status needs attention")
        }
    }

    static func frozenDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}
