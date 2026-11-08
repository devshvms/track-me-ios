import Foundation

/// TASK-356. `ride_recovered` makes the ghost-ride gap measurable. Mirrors Android's
/// `RecoveryTelemetry` so both platforms emit the same event and properties.
///
/// Orphan recovery (`RideRecoveryManager`) already ships and already resumes fresh sessions, but it
/// emitted nothing, so PostHog could not say how many "missing" rides were quietly rescued.
///
/// Privacy: coarse only — counts and a distance *bucket*, never metres, titles or ids. A raw
/// distance beside a timestamp can act as a location fingerprint.
enum RecoveryTelemetry {
    static let event = "ride_recovered"

    static func distanceBucket(totalMeters: Double) -> String {
        switch totalMeters {
        case ..<1_000: return "lt_1km"
        case ..<5_000: return "1_5km"
        case ..<20_000: return "5_20km"
        default: return "gte_20km"
        }
    }

    static func properties(recoveredCount: Int, discardedCount: Int, totalMeters: Double) -> [String: Any] {
        [
            "recovered_count": recoveredCount,
            "discarded_count": discardedCount,
            "distance_bucket": distanceBucket(totalMeters: totalMeters)
        ]
    }

    /// Nothing to report unless recovery actually changed something.
    static func shouldReport(recoveredCount: Int, discardedCount: Int) -> Bool {
        recoveredCount > 0 || discardedCount > 0
    }
}
