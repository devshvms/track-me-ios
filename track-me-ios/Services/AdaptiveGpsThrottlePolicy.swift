import Foundation
import CoreLocation

/**
 * TASK-351 (BATT-01): Adaptive GPS Polling Throttling Policy.
 *
 * When a rider or driver is stationary (e.g. stopped at long traffic lights, lunch stop,
 * or prolonged rest stop > 3 minutes), continuing to poll GPS at highest accuracy and 2m filter
 * wastes 35–45% battery on stationary drift and background CPU wakeups.
 *
 * This policy governs stepping down location polling from best accuracy and 2m filter to
 * 10m accuracy and 15m distance filter when stationary for > 3 minutes (180 seconds),
 * and instantly restoring high-accuracy polling the moment the hardware IMU accelerometer
 * or location engine detects physical movement.
 */
enum AdaptiveGpsThrottlePolicy {
    /// Minimum duration of confirmed stillness before stepping down GPS polling rate (3 minutes).
    static let stationaryThrottleThreshold: TimeInterval = 180.0

    /// Active high-accuracy settings.
    static let activeAccuracy: CLLocationAccuracy = kCLLocationAccuracyBest
    static let activeDistanceFilter: CLLocationDistance = 2.0

    /// Throttled stationary settings.
    static let throttledAccuracy: CLLocationAccuracy = kCLLocationAccuracyNearestTenMeters
    static let throttledDistanceFilter: CLLocationDistance = 15.0

    /**
     * Evaluates whether location polling should be throttled.
     *
     * - Parameters:
     *   - isStationary: true if hardware IMU or drift detector flags the device as stationary.
     *   - stillnessDuration: duration in seconds since stillness began.
     * - Returns: true if GPS polling rate should be stepped down.
     */
    static func shouldThrottle(
        isStationary: Bool,
        stillnessDuration: TimeInterval
    ) -> Bool {
        return isStationary && stillnessDuration >= stationaryThrottleThreshold
    }

    /**
     * Evaluates whether high-accuracy location polling should be restored immediately.
     *
     * - Parameters:
     *   - isCurrentlyThrottled: true if GPS polling is currently in throttled state.
     *   - isStationary: true if device is still stationary.
     * - Returns: true if high-accuracy polling should be restored immediately.
     */
    static func shouldRestore(
        isCurrentlyThrottled: Bool,
        isStationary: Bool
    ) -> Bool {
        return isCurrentlyThrottled && !isStationary
    }
}
