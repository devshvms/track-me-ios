import Foundation

/// The persisted aggregate is a checkpoint, not geometry reconstructed after a restart.
/// Resetting the estimator on restore deliberately opens a new segment: downtime is not travel.
nonisolated final class TrackingV2Session {
    private let estimator = TrackingV2Estimator()
    private var distanceOffset = 0.0
    private var previousTime: Int64?
    private var pendingDurationMillis: Int64 = 0
    private var uncreditedDurationMillis: Int64 = 0
    private var previousAutoPauseEnabled = true
    private(set) var isAutoPaused = false
    private(set) var distanceMeters = 0.0
    private(set) var movingDurationMillis: Int64 = 0
    private(set) var maxSpeedMps = 0.0
    private(set) var snapshot = TrackingV2Snapshot()

    func reset(persona: RidePersona, distance: Double = 0, duration: Int64 = 0, peak: Double = 0) {
        estimator.reset(persona: persona)
        distanceOffset = distance.isFinite ? max(0, distance) : 0
        distanceMeters = distanceOffset
        movingDurationMillis = max(0, duration)
        maxSpeedMps = peak.isFinite ? max(0, peak) : 0
        previousTime = nil
        pendingDurationMillis = 0
        uncreditedDurationMillis = 0
        previousAutoPauseEnabled = true
        isAutoPaused = false
        snapshot = estimator.snapshot()
    }

    func pause() {
        estimator.pause()
        previousTime = nil
        pendingDurationMillis = 0
        uncreditedDurationMillis = 0
        isAutoPaused = false
    }

    func resume() {
        estimator.resume()
        previousTime = nil
        pendingDurationMillis = 0
        uncreditedDurationMillis = 0
        isAutoPaused = false
    }

    @discardableResult
    func add(_ sample: TrackingV2Sample, autoPauseEnabled: Bool = true) -> TrackingV2Snapshot {
        let prior = snapshot
        snapshot = estimator.add(sample)
        guard snapshot.rejectedOutlierCount == prior.rejectedOutlierCount,
              !snapshot.manualPauseActive else { return snapshot }
        isAutoPaused = autoPauseEnabled && snapshot.movementState == .stationary
        if autoPauseEnabled != previousAutoPauseEnabled {
            pendingDurationMillis = 0
            uncreditedDurationMillis = 0
        }
        if let previousTime {
            let interval = sample.elapsedRealtimeMillis - previousTime
            // No time or speed is inferred across an unobserved gap. An explicitly counted step
            // bridge may retain its elapsed interval, but never constructs a coordinate chord.
            let hasStepBridge = snapshot.estimatedGapDistanceMeters > prior.estimatedGapDistanceMeters
            if interval > 0 && (interval <= 15_000 || hasStepBridge) {
                if !autoPauseEnabled {
                    // Debug override changes duration, never GPS drift admission.
                    movingDurationMillis += interval
                    pendingDurationMillis = 0
                    uncreditedDurationMillis = 0
                } else if snapshot.movementState == .moving || hasStepBridge {
                    movingDurationMillis += max(interval + pendingDurationMillis,
                        min(snapshot.confirmedResumeDurationMillis, uncreditedDurationMillis + interval))
                    pendingDurationMillis = 0
                    uncreditedDurationMillis = 0
                } else if snapshot.movementState == .possiblyMoving {
                    pendingDurationMillis = min(15_000, pendingDurationMillis + interval)
                } else {
                    pendingDurationMillis = 0
                }
                if autoPauseEnabled && snapshot.movementState != .moving && !hasStepBridge {
                    uncreditedDurationMillis = min(60_000, uncreditedDurationMillis + interval)
                }
                if snapshot.movementState == .moving {
                    // A multi-callback confirmation distance is not an instantaneous speed.
                    maxSpeedMps = max(maxSpeedMps, Double(snapshot.currentSpeedMetersPerSecond))
                }
            } else {
                pendingDurationMillis = 0
                uncreditedDurationMillis = 0
            }
        }
        previousTime = sample.elapsedRealtimeMillis
        previousAutoPauseEnabled = autoPauseEnabled
        distanceMeters = distanceOffset + snapshot.distanceMeters
        return snapshot
    }
}
