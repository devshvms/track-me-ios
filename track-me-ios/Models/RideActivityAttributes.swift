import ActivityKit
import Foundation

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
    }

    var rideId: String
}
