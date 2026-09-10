import Foundation

/// The persisted aggregate is a checkpoint, not geometry reconstructed after a restart.
/// Resetting the estimator on restore deliberately opens a new segment: downtime is not travel.
nonisolated final class TrackingV2Session {
    private let estimator = TrackingV2Estimator()
    private var distanceOffset = 0.0
    private var previousTime: Int64?
    private var previousDistance = 0.0
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
        previousDistance = 0
        snapshot = estimator.snapshot()
    }

    func pause() {
        estimator.pause()
        previousTime = nil
    }

    func resume() {
        estimator.resume()
        previousTime = nil
    }

    @discardableResult
    func add(_ sample: TrackingV2Sample) -> TrackingV2Snapshot {
        let prior = snapshot
        snapshot = estimator.add(sample)
        guard snapshot.rejectedOutlierCount == prior.rejectedOutlierCount,
              !snapshot.manualPauseActive else { return snapshot }
        let delta = snapshot.distanceMeters - previousDistance
        if let previousTime {
            let interval = sample.elapsedRealtimeMillis - previousTime
            // No time or speed is inferred across an unobserved gap. An explicitly counted step
            // bridge may retain its elapsed interval, but never constructs a coordinate chord.
            let hasStepBridge = snapshot.estimatedGapDistanceMeters > prior.estimatedGapDistanceMeters
            if interval > 0 && (interval <= 15_000 || hasStepBridge),
               snapshot.movementState != .stationary,
               snapshot.movementState != .unknown,
               (snapshot.movementState != .gpsDegraded || delta > 0) {
                movingDurationMillis += interval
                let intervalSpeed = max(0, delta) / (Double(interval) / 1_000)
                maxSpeedMps = max(maxSpeedMps, intervalSpeed)
                maxSpeedMps = max(maxSpeedMps, Double(snapshot.currentSpeedMetersPerSecond))
            }
        }
        previousTime = sample.elapsedRealtimeMillis
        previousDistance = snapshot.distanceMeters
        distanceMeters = distanceOffset + snapshot.distanceMeters
        return snapshot
    }
}
