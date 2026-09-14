import Foundation

/// Process-local TASK-274 shadow state. Nothing in this file is persisted or production-authoritative.
nonisolated enum TrackingV2MovementState: String, Sendable {
    case moving = "MOVING"
    case possiblyMoving = "POSSIBLY_MOVING"
    case stationary = "STATIONARY"
    case gpsDegraded = "GPS_DEGRADED"
    case unknown = "UNKNOWN"
}

nonisolated enum TrackingV2PowerMode: String, Sendable {
    case normal = "NORMAL"
    case batterySaver = "BATTERY_SAVER"
    case foregroundOnly = "FOREGROUND_ONLY"
    case gpsDisabledWhenScreenOff = "GPS_DISABLED_WHEN_SCREEN_OFF"
    case allLocationDisabled = "ALL_LOCATION_DISABLED"
    case unknown = "UNKNOWN"
}

nonisolated struct TrackingV2Point: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
}

/// Raw shadow evidence. Missing GPS speed deliberately remains nil rather than becoming zero.
nonisolated struct TrackingV2Sample: Sendable {
    let latitude: Double
    let longitude: Double
    let horizontalAccuracyMeters: Float
    let elapsedRealtimeMillis: Int64
    let gpsSpeedMetersPerSecond: Float?
    let gpsSpeedAccuracyMetersPerSecond: Float?
    let motionEnergyMetersPerSecondSquared: Float?
    let motionSampleAgeMillis: Int64?
    let cumulativeStepCount: Int64?
    let stepAgeMillis: Int64?
    let stepCadenceHz: Float?
    let persona: RidePersona
    let powerMode: TrackingV2PowerMode
}

nonisolated struct TrackingV2Snapshot: Sendable {
    var distanceMeters = 0.0
    var currentSpeedMetersPerSecond: Float = 0
    var movementState = TrackingV2MovementState.unknown
    var routeSegments: [[TrackingV2Point]] = []
    /// Admitted display points before finish-time presentation cleanup.
    var rawRouteSegments: [[TrackingV2Point]] = []
    var sampleCount = 0
    var missingSpeedCount = 0
    var powerRestrictedSampleCount = 0
    var poorAccuracySampleCount = 0
    var unobservedGapCount = 0
    var maximumSampleIntervalMillis: Int64 = 0
    /// Compatibility aggregate: power-restricted or poor-accuracy samples.
    var degradedSampleCount = 0
    var rejectedOutlierCount = 0
    var manualPauseActive = false
    var manualPauseCount = 0
    var ignoredManualPauseSampleCount = 0
    var estimatedGapStepCount: Int64 = 0
    var estimatedGapDistanceMeters = 0.0
    var personaMismatchCount = 0
    var movingEntryCount = 0
    var stationaryEntryCount = 0
    /// One-shot bounded departure evidence; the session excludes already credited time.
    var confirmedResumeDurationMillis: Int64 = 0
    var stepDistanceMeters = 0.0
    var coordinateDistanceMeters = 0.0
    var rawStepDistanceMeters = 0.0
    var calibratedStepDistanceMeters = 0.0
    var detectedStepCount: Int64 = 0
    var discardedImplausibleStepCount: Int64 = 0
    var strideLengthMeters: Float = 0.72
    var calibrationAttemptCount = 0
    var calibrationAcceptedCount = 0
    var calibrationRejectedCount = 0
    var calibrationCandidateMinMeters: Float?
    var calibrationCandidateMedianMeters: Float?
    var calibrationCandidateMaxMeters: Float?
    var pedometerAvailable = false
    var powerMode = TrackingV2PowerMode.unknown
    var isPostProcessed = false
}

///
/// Pure iOS shadow baseline for the shared replay contract. It intentionally has no CoreLocation,
/// SwiftData, UI, network, or live `TrackingManager` dependency. TASK-274B–F can evolve this logic
/// behind byte-identical vectors before a separate commit wires it to debug-only live evidence.
///
nonisolated final class TrackingV2Estimator {
    private struct Evidence {
        let coordinateSpeedMetersPerSecond: Float
        let coherentDisplacement: Bool
        let reliableGpsSpeed: Bool
        let gpsSaysMoving: Bool
        let motionFresh: Bool
        let stepsRecent: Bool
        let turnDetected: Bool
    }

    private var window: [TrackingV2Sample] = []
    private var routeSegments: [[TrackingV2Point]] = []
    private var routeSegmentAccuracies: [[Float]] = []
    private var hybridCommittedDistanceMeters = 0.0
    private var hybridBridgeStepCount: Int64 = 0
    private var coordinateDistanceMeters = 0.0
    private var detectedStepCount: Int64 = 0
    private var discardedImplausibleStepCount: Int64 = 0
    private var sampleCount = 0
    private var missingSpeedCount = 0
    private var powerRestrictedSampleCount = 0
    private var poorAccuracySampleCount = 0
    private var unobservedGapCount = 0
    private var maximumSampleIntervalMillis: Int64 = 0
    private var degradedSampleCount = 0
    private var rejectedOutlierCount = 0
    private var manualPauseActive = false
    private var manualPauseCount = 0
    private var ignoredManualPauseSampleCount = 0
    private var estimatedGapStepCount: Int64 = 0
    private var estimatedGapDistanceMeters = 0.0
    private var personaMismatchCount = 0
    private var movingEntryCount = 0
    private var stationaryEntryCount = 0
    private var activePersona = RidePersona.auto
    private var lastSample: TrackingV2Sample?
    private var lastStepCount: Int64?
    private var lastCoordinatePoint: TrackingV2Point?
    private var lastCoordinateTimeMillis: Int64?
    private var lastRoutePoint: TrackingV2Point?
    private var lastRouteTimeMillis: Int64?
    private var pendingRouteDistanceMeters = 0.0
    private var stationaryCandidateSinceMillis: Int64?
    private var lastQuietMotionMillis: Int64?
    private var stationaryConfirmed = false
    private var stopAnchor: TrackingV2Point?
    private var stopAccuracyMeters: Float = 0
    private var resumeCandidate: TrackingV2Sample?
    private var resumeRadialDistance = 0.0
    private var confirmedResumeDurationMillis: Int64 = 0
    private var gpsMovementSinceMillis: Int64?
    private var gpsMovementSamples = 0
    private var strideLengthMeters: Float = TrackingV2Estimator.defaultWalkStrideMeters
    private var calibrationStepCount: Int64?
    private var calibrationGPSDistanceMeters: Double?
    private var calibrationAccuracyMeters: Float?
    private var calibrationCandidates: [Float] = []
    private var calibrationAttemptCount = 0
    private var calibrationAcceptedCount = 0
    private var calibrationRejectedCount = 0
    private var lastSnapshot = TrackingV2Snapshot()

    func reset(persona: RidePersona = .auto) {
        window.removeAll(keepingCapacity: false)
        routeSegments.removeAll(keepingCapacity: false)
        routeSegmentAccuracies.removeAll(keepingCapacity: false)
        hybridCommittedDistanceMeters = 0
        hybridBridgeStepCount = 0
        coordinateDistanceMeters = 0
        detectedStepCount = 0
        discardedImplausibleStepCount = 0
        sampleCount = 0
        missingSpeedCount = 0
        powerRestrictedSampleCount = 0
        poorAccuracySampleCount = 0
        unobservedGapCount = 0
        maximumSampleIntervalMillis = 0
        degradedSampleCount = 0
        rejectedOutlierCount = 0
        manualPauseActive = false
        manualPauseCount = 0
        ignoredManualPauseSampleCount = 0
        estimatedGapStepCount = 0
        estimatedGapDistanceMeters = 0
        personaMismatchCount = 0
        movingEntryCount = 0
        stationaryEntryCount = 0
        activePersona = persona
        lastSample = nil
        lastStepCount = nil
        lastCoordinatePoint = nil
        lastCoordinateTimeMillis = nil
        lastRoutePoint = nil
        lastRouteTimeMillis = nil
        pendingRouteDistanceMeters = 0
        stationaryCandidateSinceMillis = nil
        lastQuietMotionMillis = nil
        stationaryConfirmed = false
        clearStopAnchor()
        confirmedResumeDurationMillis = 0
        gpsMovementSinceMillis = nil
        gpsMovementSamples = 0
        strideLengthMeters = defaultStride(for: persona)
        calibrationStepCount = nil
        calibrationGPSDistanceMeters = nil
        calibrationAccuracyMeters = nil
        calibrationCandidates.removeAll(keepingCapacity: false)
        calibrationAttemptCount = 0
        calibrationAcceptedCount = 0
        calibrationRejectedCount = 0
        lastSnapshot = TrackingV2Snapshot(strideLengthMeters: strideLengthMeters)
    }

    /// Manual pause/resume and unobserved gaps split geometry and reset every distance anchor.
    func markDiscontinuity() {
        freezeOpenStepBridge()
        clearContinuityAnchors()
    }

    /// Manual pause is an explicit control fact; callbacks observed during it are ignored.
    func pause() {
        guard !manualPauseActive else { return }
        manualPauseActive = true
        manualPauseCount += 1
        freezeOpenStepBridge()
        clearContinuityAnchors()
        lastSnapshot.manualPauseActive = true
        lastSnapshot.manualPauseCount = manualPauseCount
    }

    /// Resume is idempotent and establishes fresh coordinate and pedometer baselines.
    func resume() {
        guard manualPauseActive else { return }
        manualPauseActive = false
        clearContinuityAnchors()
        lastSnapshot.manualPauseActive = false
    }

    private func clearContinuityAnchors() {
        window.removeAll(keepingCapacity: false)
        lastSample = nil
        lastStepCount = nil
        lastCoordinatePoint = nil
        lastCoordinateTimeMillis = nil
        lastRoutePoint = nil
        lastRouteTimeMillis = nil
        pendingRouteDistanceMeters = 0
        stationaryCandidateSinceMillis = nil
        lastQuietMotionMillis = nil
        stationaryConfirmed = false
        clearStopAnchor()
        gpsMovementSinceMillis = nil
        gpsMovementSamples = 0
        calibrationStepCount = nil
        calibrationGPSDistanceMeters = nil
        calibrationAccuracyMeters = nil
    }

    @discardableResult
    func add(_ incoming: TrackingV2Sample) -> TrackingV2Snapshot {
        confirmedResumeDurationMillis = 0
        if manualPauseActive {
            ignoredManualPauseSampleCount += 1
            lastSnapshot.manualPauseActive = true
            lastSnapshot.ignoredManualPauseSampleCount = ignoredManualPauseSampleCount
            return lastSnapshot
        }
        let sample: TrackingV2Sample
        if incoming.persona == activePersona {
            sample = incoming
        } else {
            personaMismatchCount += 1
            sample = incoming.with(persona: activePersona)
        }
        if let previous = lastSample, sample.elapsedRealtimeMillis <= previous.elapsedRealtimeMillis {
            rejectedOutlierCount += 1
            return publish(sample, state: .gpsDegraded, speed: 0)
        }

        sampleCount += 1
        if sample.gpsSpeedMetersPerSecond == nil { missingSpeedCount += 1 }
        let powerRestricted = sample.powerMode != .normal
        if powerRestricted { powerRestrictedSampleCount += 1 }
        let poorAccuracy = hasPoorAccuracy(sample)
        if poorAccuracy { poorAccuracySampleCount += 1 }
        let degraded = powerRestricted || poorAccuracy
        if degraded { degradedSampleCount += 1 }

        guard let previous = lastSample else {
            window.append(sample)
            lastSample = sample
            lastStepCount = sample.cumulativeStepCount
            calibrationStepCount = sample.cumulativeStepCount
            calibrationGPSDistanceMeters = coordinateDistanceMeters
            calibrationAccuracyMeters = sample.horizontalAccuracyMeters
            return publish(
                sample,
                state: degraded ? .gpsDegraded : .unknown,
                speed: 0
            )
        }

        let deltaMillis = sample.elapsedRealtimeMillis - previous.elapsedRealtimeMillis
        maximumSampleIntervalMillis = max(maximumSampleIntervalMillis, deltaMillis)
        if deltaMillis > Self.maxObservedGapMillis {
            unobservedGapCount += 1
            freezeOpenStepBridge()
            let gapSteps: Int64
            if isPedestrian(activePersona),
               sample.stepAgeMillis.map({ (0...Self.stepRecencyMillis).contains($0) }) == true {
                gapSteps = stepDelta(from: previous, to: sample)
            } else {
                gapSteps = 0
            }
            if gapSteps > 0 {
                let gapDistance = Double(gapSteps) * Double(strideLengthMeters)
                estimatedGapStepCount += gapSteps
                estimatedGapDistanceMeters += gapDistance
                hybridCommittedDistanceMeters += gapDistance
            }
            clearContinuityAnchors()
            window.append(sample)
            lastSample = sample
            lastStepCount = sample.cumulativeStepCount
            calibrationStepCount = sample.cumulativeStepCount
            calibrationGPSDistanceMeters = coordinateDistanceMeters
            calibrationAccuracyMeters = sample.horizontalAccuracyMeters
            return publish(sample, state: .gpsDegraded, speed: 0)
        }

        // Keep impossible raw jumps out of regression and turn detection; retain the credible anchor.
        guard isPlausible(Self.haversineMeters(previous.point, sample.point), sample: sample,
                          previousTimeMillis: previous.elapsedRealtimeMillis) else {
            rejectedOutlierCount += 1
            return publish(sample, state: .gpsDegraded, speed: 0)
        }
        window.append(sample)
        pruneWindow(for: sample)
        let evidence = movementEvidence(for: sample)
        let admittedSteps = stepDelta(from: previous, to: sample)
        let state = classify(sample, evidence: evidence, stepDelta: admittedSteps)
        let speed: Float = state == .moving ? fusedSpeed(sample, evidence: evidence, stepDelta: admittedSteps) : 0

        if state == .moving {
            let smoothedPoint = smoothCurrentPoint(sample, turnDetected: evidence.turnDetected)
            let pedestrian = isPedestrian(sample.persona)
            let coordinateReady = window.count >= minimumCoordinateWindowSize(for: sample.powerMode)
                && (evidence.coherentDisplacement || evidence.gpsSaysMoving)
            let admittedCoordinateMeters = coordinateReady
                ? admitCoordinateDistance(
                    distancePoint(for: sample, smoothed: smoothedPoint),
                    sample: sample,
                    turnDetected: evidence.turnDetected
                )
                : 0

            if pedestrian, sample.cumulativeStepCount != nil {
                hybridBridgeStepCount += admittedSteps
                if admittedCoordinateMeters > 0 {
                    hybridCommittedDistanceMeters += admittedCoordinateMeters
                    hybridBridgeStepCount = 0
                }
                calibrateStride(sample)
                // Steps prove travel, but cannot locate it within an uncertain GPS cloud.
                if coordinateReady || !hasPoorAccuracy(sample) {
                    appendRoutePoint(smoothedPoint, sample: sample, turnDetected: evidence.turnDetected)
                }
            } else if admittedCoordinateMeters > 0 {
                hybridCommittedDistanceMeters += admittedCoordinateMeters
                appendRoutePoint(smoothedPoint, sample: sample, turnDetected: evidence.turnDetected)
            }
        } else if state == .stationary {
            freezeOpenStepBridge()
            lastCoordinatePoint = smoothCurrentPoint(sample, turnDetected: false)
            lastCoordinateTimeMillis = sample.elapsedRealtimeMillis
        }

        lastSample = sample
        if let steps = sample.cumulativeStepCount { lastStepCount = steps }
        return publish(sample, state: state, speed: speed)
    }

    func finish() -> TrackingV2Snapshot {
        let raw = routeSegments
        let compressed = routeSegments.enumerated().compactMap { index, segment -> [TrackingV2Point]? in
            guard !segment.isEmpty else { return nil }
            guard segment.count > 2 else { return segment }
            let accuracies = routeSegmentAccuracies.indices.contains(index)
                ? routeSegmentAccuracies[index].sorted()
                : []
            let medianAccuracy = Double(accuracies.indices.contains(accuracies.count / 2)
                ? accuracies[accuracies.count / 2]
                : 6)
            let maximumEpsilon = lastSnapshot.powerMode == .normal ? 5.0 : 8.0
            let epsilon = (medianAccuracy * 0.25).clamped(to: 1.5...maximumEpsilon)
            return simplify(segment, epsilonMeters: epsilon)
        }
        lastSnapshot.routeSegments = compressed
        lastSnapshot.rawRouteSegments = raw
        lastSnapshot.manualPauseActive = manualPauseActive
        lastSnapshot.isPostProcessed = true
        return lastSnapshot
    }

    func snapshot() -> TrackingV2Snapshot { lastSnapshot }

    private func movementEvidence(for sample: TrackingV2Sample) -> Evidence {
        guard let first = window.first else {
            return Evidence(coordinateSpeedMetersPerSecond: 0, coherentDisplacement: false,
                            reliableGpsSpeed: false, gpsSaysMoving: false, motionFresh: false,
                            stepsRecent: false, turnDetected: false)
        }
        let elapsedSeconds = max(0.001, Double(sample.elapsedRealtimeMillis - first.elapsedRealtimeMillis) / 1_000)
        let coordinateDistance = Self.haversineMeters(first.point, sample.point)
        let windowLegs = zip(window, window.dropFirst()).map { Self.haversineMeters($0.point, $1.point) }
        let windowPath = windowLegs.reduce(0, +)
        let pathStraightness = windowPath <= 0.001 ? 0 : Float(coordinateDistance / windowPath).clamped(to: 0...1)
        let combinedAccuracy = hypot(
            max(1, sample.horizontalAccuracyMeters),
            max(1, first.horizontalAccuracyMeters)
        )
        let uncertaintyScale: Float = sample.powerMode == .normal ? 0.72 : 0.95
        let significantDistance = max(Self.minimumCoherentDisplacementMeters, combinedAccuracy * uncertaintyScale)
        let coordinateSpeed = Float(coordinateDistance / elapsedSeconds)
        let mature = window.count >= Self.minimumCoordinateEvidenceSamples
            && sample.elapsedRealtimeMillis - first.elapsedRealtimeMillis >= Self.minimumCoordinateEvidenceMillis
        let coherent = mature && coordinateDistance >= Double(significantDistance)
            && pathStraightness >= Self.minimumPathStraightness
            && (windowLegs.max() ?? 0) <= windowPath * 0.8

        let reliableGpsSpeed: Bool
        if let speed = sample.gpsSpeedMetersPerSecond, speed.isFinite, speed >= 0 {
            if let accuracy = sample.gpsSpeedAccuracyMetersPerSecond {
                reliableGpsSpeed = accuracy.isFinite && accuracy >= 0 && accuracy <= max(0.8, speed * 0.6)
            } else {
                reliableGpsSpeed = sample.horizontalAccuracyMeters <= 15
            }
        } else {
            reliableGpsSpeed = false
        }
        let gpsSaysMoving = reliableGpsSpeed
            && (sample.gpsSpeedMetersPerSecond ?? 0) - (sample.gpsSpeedAccuracyMetersPerSecond ?? 0.5)
                >= movementSpeedThreshold(for: sample.persona)
        let freshnessLimit: Int64 = sample.powerMode == .normal ? 1_500 : 3_000
        let motionFresh = sample.motionSampleAgeMillis.map { (0...freshnessLimit).contains($0) } ?? false
        let stepsRecent = sample.stepAgeMillis.map { (0...Self.stepRecencyMillis).contains($0) } ?? false
        return Evidence(
            coordinateSpeedMetersPerSecond: coordinateSpeed,
            coherentDisplacement: coherent,
            reliableGpsSpeed: reliableGpsSpeed,
            gpsSaysMoving: gpsSaysMoving,
            motionFresh: motionFresh,
            stepsRecent: stepsRecent,
            turnDetected: detectsTurn()
        )
    }

    private func classify(
        _ sample: TrackingV2Sample,
        evidence: Evidence,
        stepDelta: Int64
    ) -> TrackingV2MovementState {
        let pedestrianEvidence = (isPedestrian(sample.persona) || sample.persona == .auto)
            && (stepDelta > 0 || evidence.stepsRecent)
        let coherentMovement = evidence.coherentDisplacement
            && evidence.coordinateSpeedMetersPerSecond >= movementSpeedThreshold(for: sample.persona)
        if evidence.gpsSaysMoving {
            if gpsMovementSinceMillis == nil { gpsMovementSinceMillis = sample.elapsedRealtimeMillis }
            gpsMovementSamples += 1
        } else {
            gpsMovementSinceMillis = nil
            gpsMovementSamples = 0
        }
        let gpsMovementProved = gpsMovementSamples >= Self.minimumCoordinateEvidenceSamples
            && gpsMovementSinceMillis.map {
                sample.elapsedRealtimeMillis - $0 >= Self.minimumCoordinateEvidenceMillis
            } == true
        // Handling plus a raw GPS chord is not travel. A confirmed stop also needs an outward
        // departure from its fixed uncertainty region, not just a locally straight drift window.
        let gpsDeparture = stationaryConfirmed
            ? confirmedGpsDeparture(sample, coherentMovement: coherentMovement)
            : gpsMovementProved || coherentMovement
        let movementProved = pedestrianEvidence || gpsDeparture

        if movementProved {
            stationaryCandidateSinceMillis = nil
            lastQuietMotionMillis = nil
            stationaryConfirmed = false
            clearStopAnchor()
            return .moving
        }

        let dwell = stationaryDwellMillis(for: sample.persona, powerMode: sample.powerMode)
        let quietMotion = evidence.motionFresh
            && (sample.motionEnergyMetersPerSecondSquared ?? .greatestFiniteMagnitude) < Self.motionMovingEnergy
        if quietMotion { lastQuietMotionMillis = sample.elapsedRealtimeMillis }
        let recentQuietMotion = lastQuietMotionMillis.map { sample.elapsedRealtimeMillis - $0 <= dwell } == true
        // Missing motion cannot establish a new stop, but does not erase an already confirmed one
        // while GPS callbacks remain continuous. Gaps/manual pause reset these anchors explicitly.
        let stationaryCandidate = stationaryConfirmed || (evidence.motionFresh && recentQuietMotion)
        if stationaryCandidate {
            let since = stationaryCandidateSinceMillis ?? sample.elapsedRealtimeMillis
            stationaryCandidateSinceMillis = since
            if stationaryConfirmed || sample.elapsedRealtimeMillis - since >= dwell {
                if !stationaryConfirmed {
                    stopAnchor = smoothCurrentPoint(sample, turnDetected: false)
                    stopAccuracyMeters = sample.horizontalAccuracyMeters
                }
                stationaryConfirmed = true
                return .stationary
            }
            return .possiblyMoving
        }

        stationaryCandidateSinceMillis = nil
        if evidence.gpsSaysMoving { return .possiblyMoving }
        return isDegraded(sample) ? .gpsDegraded : .unknown
    }

    private func confirmedGpsDeparture(_ sample: TrackingV2Sample, coherentMovement: Bool) -> Bool {
        guard let anchor = stopAnchor else { return false }
        let radial = Self.haversineMeters(anchor, sample.point)
        if !coherentMovement || radial + 1 < resumeRadialDistance {
            resumeCandidate = nil
            resumeRadialDistance = radial
            return false
        }
        if resumeCandidate.map({ sample.elapsedRealtimeMillis - $0.elapsedRealtimeMillis > 60_000 }) ?? true {
            resumeCandidate = zip(window, window.dropFirst()).first { a, b in
                Self.haversineMeters(a.point, b.point) >= max(0.5,
                    Double(movementSpeedThreshold(for: sample.persona)) *
                    Double(b.elapsedRealtimeMillis - a.elapsedRealtimeMillis) / 1_000)
            }?.0 ?? sample
        }
        guard let candidate = resumeCandidate else { return false }
        resumeRadialDistance = radial
        let radius = max(20.0, hypot(Double(stopAccuracyMeters), Double(sample.horizontalAccuracyMeters)))
        guard radial > radius,
              sample.elapsedRealtimeMillis - candidate.elapsedRealtimeMillis >= 4_000 else { return false }
        // Backfill only the bounded, proved departure, never the preceding seated interval.
        confirmedResumeDurationMillis = min(60_000, max(0,
            sample.elapsedRealtimeMillis - candidate.elapsedRealtimeMillis))
        lastCoordinatePoint = candidate.point
        lastCoordinateTimeMillis = candidate.elapsedRealtimeMillis
        return true
    }

    private func clearStopAnchor() {
        stopAnchor = nil
        stopAccuracyMeters = 0
        resumeCandidate = nil
        resumeRadialDistance = 0
    }

    private func fusedSpeed(
        _ sample: TrackingV2Sample,
        evidence: Evidence,
        stepDelta: Int64
    ) -> Float {
        var candidates: [(value: Float, weight: Float)] = []
        if evidence.reliableGpsSpeed {
            let accuracy = sample.gpsSpeedAccuracyMetersPerSecond ?? 1
            candidates.append((sample.gpsSpeedMetersPerSecond ?? 0, 1 / max(0.25, accuracy * accuracy)))
        }
        if evidence.coherentDisplacement {
            candidates.append((evidence.coordinateSpeedMetersPerSecond,
                               1 / max(4, sample.horizontalAccuracyMeters * sample.horizontalAccuracyMeters)))
        }
        if (stepDelta > 0 || evidence.stepsRecent), let cadence = sample.stepCadenceHz {
            candidates.append((cadence * strideLengthMeters, 1.5))
        }
        let totalWeight = max(0.001, candidates.reduce(0) { $0 + $1.weight })
        return max(0, candidates.reduce(0) { $0 + $1.value * $1.weight } / totalWeight)
    }

    private func admitCoordinateDistance(
        _ point: TrackingV2Point,
        sample: TrackingV2Sample,
        turnDetected: Bool
    ) -> Double {
        guard let previousPoint = lastCoordinatePoint, let previousTime = lastCoordinateTimeMillis else {
            let origin = window.first?.point ?? point
            let distance = Self.haversineMeters(origin, point)
            guard isPlausible(distance, sample: sample, previousTimeMillis: window.first?.elapsedRealtimeMillis) else {
                rejectedOutlierCount += 1
                return 0
            }
            lastCoordinatePoint = point
            lastCoordinateTimeMillis = sample.elapsedRealtimeMillis
            let admitted = turnDetected ? distance : alongWindowAxisMeters(from: origin, to: point)
            coordinateDistanceMeters += admitted
            return admitted
        }

        let distance = Self.haversineMeters(previousPoint, point)
        guard isPlausible(distance, sample: sample, previousTimeMillis: previousTime) else {
            rejectedOutlierCount += 1
            return 0
        }
        let admitted = turnDetected ? distance : alongWindowAxisMeters(from: previousPoint, to: point)
        coordinateDistanceMeters += admitted
        lastCoordinatePoint = point
        lastCoordinateTimeMillis = sample.elapsedRealtimeMillis
        return admitted
    }

    private func appendRoutePoint(
        _ point: TrackingV2Point,
        sample: TrackingV2Sample,
        turnDetected: Bool
    ) {
        guard let previousPoint = lastRoutePoint, let previousTime = lastRouteTimeMillis else {
            let origin = window.first?.point ?? point
            var segment = [origin]
            if Self.haversineMeters(origin, point) >= 0.5 { segment.append(point) }
            routeSegments.append(segment)
            var accuracies = [window.first?.horizontalAccuracyMeters ?? sample.horizontalAccuracyMeters]
            if segment.count > 1 { accuracies.append(sample.horizontalAccuracyMeters) }
            routeSegmentAccuracies.append(accuracies)
            lastRoutePoint = point
            lastRouteTimeMillis = sample.elapsedRealtimeMillis
            return
        }

        let distance = Self.haversineMeters(previousPoint, point)
        guard isPlausible(distance, sample: sample, previousTimeMillis: previousTime) else {
            rejectedOutlierCount += 1
            return
        }
        pendingRouteDistanceMeters += distance
        let threshold = isPedestrian(sample.persona) ? 1.0 : 2.5
        if pendingRouteDistanceMeters >= threshold || turnDetected {
            if routeSegments.isEmpty { routeSegments.append([previousPoint]) }
            routeSegments[routeSegments.count - 1].append(point)
            if routeSegmentAccuracies.isEmpty {
                routeSegmentAccuracies.append([sample.horizontalAccuracyMeters])
            }
            routeSegmentAccuracies[routeSegmentAccuracies.count - 1].append(sample.horizontalAccuracyMeters)
            pendingRouteDistanceMeters = 0
        }
        lastRoutePoint = point
        lastRouteTimeMillis = sample.elapsedRealtimeMillis
    }

    private func isPlausible(
        _ distance: Double,
        sample: TrackingV2Sample,
        previousTimeMillis: Int64?
    ) -> Bool {
        guard let previousTimeMillis else { return true }
        let deltaSeconds = max(0.001, Double(sample.elapsedRealtimeMillis - previousTimeMillis) / 1_000)
        let personaCeiling: Float = switch sample.persona {
        case .walk: 4
        case .run: 8
        case .cycling: 25
        case .bikeDrive: 70
        case .carDrive, .auto: 80
        }
        let observedCeiling = sample.gpsSpeedMetersPerSecond
            .flatMap { $0.isFinite && $0 >= 0 ? max(personaCeiling, $0 * 2) : nil }
            ?? personaCeiling
        let plausibleDistance = max(
            20,
            Double(observedCeiling) * deltaSeconds * 1.5
                + Double(max(1, sample.horizontalAccuracyMeters)) * 1.5
        )
        return distance <= plausibleDistance
    }

    /// Suppress cross-track GPS oscillation from stats while retaining progress along the window.
    private func alongWindowAxisMeters(from start: TrackingV2Point, to end: TrackingV2Point) -> Double {
        guard let axisStart = window.first?.point, let axisEnd = window.last?.point else {
            return Self.haversineMeters(start, end)
        }
        let referenceLatitude = ((axisStart.latitude + axisEnd.latitude) / 2) * .pi / 180
        func deltaMeters(_ first: TrackingV2Point, _ second: TrackingV2Point) -> (east: Double, north: Double) {
            let east = (second.longitude - first.longitude) * .pi / 180
                * Self.earthRadiusMeters * cos(referenceLatitude)
            let north = (second.latitude - first.latitude) * .pi / 180 * Self.earthRadiusMeters
            return (east, north)
        }
        let axis = deltaMeters(axisStart, axisEnd)
        let axisLength = hypot(axis.east, axis.north)
        guard axisLength >= 0.5 else { return 0 }
        let segment = deltaMeters(start, end)
        return abs(segment.east * axis.east + segment.north * axis.north) / axisLength
    }

    private func calibrateStride(_ sample: TrackingV2Sample) {
        guard let steps = sample.cumulativeStepCount else { return }
        guard let anchorSteps = calibrationStepCount,
              let anchorGPSDistance = calibrationGPSDistanceMeters,
              let anchorAccuracy = calibrationAccuracyMeters else {
            calibrationStepCount = steps
            calibrationGPSDistanceMeters = coordinateDistanceMeters
            calibrationAccuracyMeters = sample.horizontalAccuracyMeters
            return
        }
        let deltaSteps = steps - anchorSteps
        guard deltaSteps >= Self.minimumCalibrationSteps else { return }
        let gpsDistance = max(0, coordinateDistanceMeters - anchorGPSDistance)
        let combinedAccuracy = hypot(max(1, anchorAccuracy), max(1, sample.horizontalAccuracyMeters))
        let minimumReliableBaseline = max(
            Self.minimumCalibrationDistanceMeters,
            Double(combinedAccuracy * Self.calibrationUncertaintyMultiplier)
        )
        let accuracyGoodEnough = anchorAccuracy <= Self.maximumCalibrationAccuracyMeters
            && sample.horizontalAccuracyMeters <= Self.maximumCalibrationAccuracyMeters
        let baselineGoodEnough = gpsDistance >= minimumReliableBaseline
        let candidate = Float(gpsDistance / Double(deltaSteps))
        let definitive = accuracyGoodEnough && baselineGoodEnough
        if !definitive && deltaSteps < Self.maximumCalibrationSteps { return }

        calibrationAttemptCount += 1
        if definitive, (Self.minimumStrideMeters...Self.maximumStrideMeters).contains(candidate) {
            calibrationAcceptedCount += 1
            calibrationCandidates.append(candidate)
            if calibrationCandidates.count > Self.maximumCalibrationCandidates {
                calibrationCandidates.removeFirst(calibrationCandidates.count - Self.maximumCalibrationCandidates)
            }
            let sorted = calibrationCandidates.sorted()
            let robustCandidate = sorted[sorted.count / 2]
            strideLengthMeters = calibrationCandidates.count < 3
                ? strideLengthMeters * 0.8 + robustCandidate * 0.2
                : robustCandidate
        } else {
            calibrationRejectedCount += 1
        }
        calibrationStepCount = steps
        calibrationGPSDistanceMeters = coordinateDistanceMeters
        calibrationAccuracyMeters = sample.horizontalAccuracyMeters
    }

    private func stepDelta(from previous: TrackingV2Sample, to sample: TrackingV2Sample) -> Int64 {
        guard let current = sample.cumulativeStepCount, let lastStepCount else { return 0 }
        let rawDelta = current - lastStepCount
        guard rawDelta > 0 else { return 0 }
        let elapsedSeconds = max(0.001, Double(sample.elapsedRealtimeMillis - previous.elapsedRealtimeMillis) / 1_000)
        let plausibleMaximum = Int64(ceil(elapsedSeconds * Self.maximumPlausibleStepHz))
            + Self.stepDeltaJitterAllowance
        let admitted = min(rawDelta, plausibleMaximum)
        detectedStepCount += admitted
        discardedImplausibleStepCount += rawDelta - admitted
        return admitted
    }

    private func freezeOpenStepBridge() {
        guard hybridBridgeStepCount > 0 else { return }
        hybridCommittedDistanceMeters += Double(hybridBridgeStepCount) * Double(strideLengthMeters)
        hybridBridgeStepCount = 0
    }

    /// Accuracy-weighted, time-aware display smoothing bounded by observations to avoid overshoot.
    private func smoothCurrentPoint(_ sample: TrackingV2Sample, turnDetected: Bool) -> TrackingV2Point {
        if turnDetected { return sample.point }
        let maximumPoints = sample.powerMode == .normal ? 5 : 8
        let selected = Array(window.suffix(maximumPoints))
        guard selected.count >= 2 else { return sample.point }
        func boundedPrediction(_ value: (TrackingV2Sample) -> Double) -> Double {
            let values = selected.map(value)
            return predictLatest(selected, value: value).clamped(to: values.min()!...values.max()!)
        }
        return TrackingV2Point(
            latitude: boundedPrediction { $0.latitude },
            longitude: boundedPrediction { $0.longitude }
        )
    }

    private func predictLatest(
        _ samples: [TrackingV2Sample],
        value: (TrackingV2Sample) -> Double
    ) -> Double {
        guard let first = samples.first, let last = samples.last else { return 0 }
        let originMillis = first.elapsedRealtimeMillis
        var sumWeight = 0.0
        var sumTime = 0.0
        var sumValue = 0.0
        var sumTimeSquared = 0.0
        var sumTimeValue = 0.0
        for candidate in samples {
            let time = Double(candidate.elapsedRealtimeMillis - originMillis) / 1_000
            let accuracy = Double(max(2, candidate.horizontalAccuracyMeters))
            let weight = 1 / (accuracy * accuracy)
            let coordinate = value(candidate)
            sumWeight += weight
            sumTime += weight * time
            sumValue += weight * coordinate
            sumTimeSquared += weight * time * time
            sumTimeValue += weight * time * coordinate
        }
        let denominator = sumWeight * sumTimeSquared - sumTime * sumTime
        guard sumWeight > 0, abs(denominator) >= 1e-15 else { return value(last) }
        let slope = (sumWeight * sumTimeValue - sumTime * sumValue) / denominator
        let intercept = (sumValue - slope * sumTime) / sumWeight
        let latestTime = Double(last.elapsedRealtimeMillis - originMillis) / 1_000
        return intercept + slope * latestTime
    }

    private func distancePoint(for sample: TrackingV2Sample, smoothed: TrackingV2Point) -> TrackingV2Point {
        let rawWeight = sample.powerMode == .normal ? 0.12 : 0.18
        return TrackingV2Point(
            latitude: sample.latitude * rawWeight + smoothed.latitude * (1 - rawWeight),
            longitude: sample.longitude * rawWeight + smoothed.longitude * (1 - rawWeight)
        )
    }

    private func detectsTurn() -> Bool {
        guard window.count >= 5 else { return false }
        let middleIndex = window.count / 2
        let first = window[0]
        let middle = window[middleIndex]
        let last = window[window.count - 1]
        let firstLeg = Self.haversineMeters(first.point, middle.point)
        let secondLeg = Self.haversineMeters(middle.point, last.point)
        let accuracyFloor = max(
            5,
            Double(first.horizontalAccuracyMeters + middle.horizontalAccuracyMeters + last.horizontalAccuracyMeters) / 2
        )
        guard firstLeg >= accuracyFloor, secondLeg >= accuracyFloor else { return false }
        let firstLegPath = zip(window[0...middleIndex], window[1...middleIndex]).reduce(0.0) {
            $0 + Self.haversineMeters($1.0.point, $1.1.point)
        }
        let secondLegPath = zip(window[middleIndex...], window[(middleIndex + 1)...]).reduce(0.0) {
            $0 + Self.haversineMeters($1.0.point, $1.1.point)
        }
        guard firstLeg / max(0.001, firstLegPath) >= Self.minimumTurnLegStraightness,
              secondLeg / max(0.001, secondLegPath) >= Self.minimumTurnLegStraightness else {
            return false
        }
        let change = Self.bearingDeltaDegrees(
            Self.bearingDegrees(first.point, middle.point),
            Self.bearingDegrees(middle.point, last.point)
        )
        return change >= Self.turnDegrees
    }

    private func publish(
        _ sample: TrackingV2Sample,
        state: TrackingV2MovementState,
        speed: Float
    ) -> TrackingV2Snapshot {
        let rawStepDistance = Double(detectedStepCount) * Double(defaultStride(for: sample.persona))
        let calibratedStepDistance = Double(detectedStepCount) * Double(strideLengthMeters)
        let pedestrianWithSteps = isPedestrian(sample.persona) && sample.cumulativeStepCount != nil
        let hybridDistance = pedestrianWithSteps
            ? hybridCommittedDistanceMeters + Double(hybridBridgeStepCount) * Double(strideLengthMeters)
            : coordinateDistanceMeters
        if state == .moving, lastSnapshot.movementState != state { movingEntryCount += 1 }
        if state == .stationary, lastSnapshot.movementState != state { stationaryEntryCount += 1 }
        let sortedCandidates = calibrationCandidates.sorted()
        lastSnapshot = TrackingV2Snapshot(
            distanceMeters: hybridDistance,
            currentSpeedMetersPerSecond: max(0, speed),
            movementState: state,
            routeSegments: routeSegments,
            rawRouteSegments: routeSegments,
            sampleCount: sampleCount,
            missingSpeedCount: missingSpeedCount,
            powerRestrictedSampleCount: powerRestrictedSampleCount,
            poorAccuracySampleCount: poorAccuracySampleCount,
            unobservedGapCount: unobservedGapCount,
            maximumSampleIntervalMillis: maximumSampleIntervalMillis,
            degradedSampleCount: degradedSampleCount,
            rejectedOutlierCount: rejectedOutlierCount,
            manualPauseActive: manualPauseActive,
            manualPauseCount: manualPauseCount,
            ignoredManualPauseSampleCount: ignoredManualPauseSampleCount,
            estimatedGapStepCount: estimatedGapStepCount,
            estimatedGapDistanceMeters: estimatedGapDistanceMeters,
            personaMismatchCount: personaMismatchCount,
            movingEntryCount: movingEntryCount,
            stationaryEntryCount: stationaryEntryCount,
            confirmedResumeDurationMillis: confirmedResumeDurationMillis,
            stepDistanceMeters: calibratedStepDistance,
            coordinateDistanceMeters: coordinateDistanceMeters,
            rawStepDistanceMeters: rawStepDistance,
            calibratedStepDistanceMeters: calibratedStepDistance,
            detectedStepCount: detectedStepCount,
            discardedImplausibleStepCount: discardedImplausibleStepCount,
            strideLengthMeters: strideLengthMeters,
            calibrationAttemptCount: calibrationAttemptCount,
            calibrationAcceptedCount: calibrationAcceptedCount,
            calibrationRejectedCount: calibrationRejectedCount,
            calibrationCandidateMinMeters: sortedCandidates.first,
            calibrationCandidateMedianMeters: sortedCandidates.isEmpty ? nil : sortedCandidates[sortedCandidates.count / 2],
            calibrationCandidateMaxMeters: sortedCandidates.last,
            pedometerAvailable: sample.cumulativeStepCount != nil,
            powerMode: sample.powerMode,
            isPostProcessed: false
        )
        return lastSnapshot
    }

    private func pruneWindow(for sample: TrackingV2Sample) {
        let duration = sample.powerMode == .normal ? Self.normalWindowMillis : Self.degradedWindowMillis
        while window.count > 2,
              let first = window.first,
              sample.elapsedRealtimeMillis - first.elapsedRealtimeMillis > duration {
            window.removeFirst()
        }
        if window.count > Self.maximumWindowSamples {
            window.removeFirst(window.count - Self.maximumWindowSamples)
        }
    }

    private func isDegraded(_ sample: TrackingV2Sample) -> Bool {
        sample.powerMode != .normal || hasPoorAccuracy(sample)
    }

    private func hasPoorAccuracy(_ sample: TrackingV2Sample) -> Bool {
        sample.horizontalAccuracyMeters > Self.poorAccuracyMeters
    }

    private func minimumCoordinateWindowSize(for powerMode: TrackingV2PowerMode) -> Int {
        powerMode == .normal ? 5 : 3
    }

    private func stationaryDwellMillis(for persona: RidePersona, powerMode: TrackingV2PowerMode) -> Int64 {
        let base: Int64 = switch persona {
        case .run, .cycling, .bikeDrive, .carDrive: 5_000
        case .walk, .auto: 6_000
        }
        return powerMode == .normal ? base : max(base, 10_000)
    }

    private func movementSpeedThreshold(for persona: RidePersona) -> Float {
        switch persona {
        case .walk: 0.2
        case .run: 0.5
        case .cycling: 0.8
        case .bikeDrive: 1.0
        case .carDrive: 1.2
        case .auto: 0.6
        }
    }

    private func defaultStride(for persona: RidePersona) -> Float {
        persona == .run ? Self.defaultRunStrideMeters : Self.defaultWalkStrideMeters
    }

    private func isPedestrian(_ persona: RidePersona) -> Bool {
        persona == .walk || persona == .run
    }

    private func simplify(_ points: [TrackingV2Point], epsilonMeters: Double) -> [TrackingV2Point] {
        guard points.count > 2 else { return points }
        var maximumDistance = 0.0
        var splitIndex = 0
        for index in 1..<points.count - 1 {
            let distance = perpendicularDistanceMeters(
                points[index],
                start: points[0],
                end: points[points.count - 1]
            )
            if distance > maximumDistance {
                maximumDistance = distance
                splitIndex = index
            }
        }
        guard maximumDistance > epsilonMeters, splitIndex > 0 else {
            return [points[0], points[points.count - 1]]
        }
        let left = simplify(Array(points[...splitIndex]), epsilonMeters: epsilonMeters)
        let right = simplify(Array(points[splitIndex...]), epsilonMeters: epsilonMeters)
        return Array(left.dropLast()) + right
    }

    private func perpendicularDistanceMeters(
        _ point: TrackingV2Point,
        start: TrackingV2Point,
        end: TrackingV2Point
    ) -> Double {
        let referenceLatitude = ((start.latitude + end.latitude + point.latitude) / 3) * .pi / 180
        func local(_ candidate: TrackingV2Point) -> (x: Double, y: Double) {
            let x = (candidate.longitude - start.longitude) * .pi / 180
                * Self.earthRadiusMeters * cos(referenceLatitude)
            let y = (candidate.latitude - start.latitude) * .pi / 180 * Self.earthRadiusMeters
            return (x, y)
        }
        let projected = local(point)
        let endpoint = local(end)
        let denominator = endpoint.x * endpoint.x + endpoint.y * endpoint.y
        guard denominator > 0 else { return hypot(projected.x, projected.y) }
        let position = ((projected.x * endpoint.x + projected.y * endpoint.y) / denominator)
            .clamped(to: 0...1)
        return hypot(projected.x - position * endpoint.x, projected.y - position * endpoint.y)
    }

    static func haversineMeters(_ first: TrackingV2Point, _ second: TrackingV2Point) -> Double {
        let lat1 = first.latitude * .pi / 180
        let lat2 = second.latitude * .pi / 180
        let deltaLat = lat2 - lat1
        let deltaLon = (second.longitude - first.longitude) * .pi / 180
        let h = sin(deltaLat / 2) * sin(deltaLat / 2)
            + cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        return 2 * Self.earthRadiusMeters * asin(sqrt(h.clamped(to: 0...1)))
    }

    private static func bearingDegrees(_ first: TrackingV2Point, _ second: TrackingV2Point) -> Float {
        let lat1 = first.latitude * .pi / 180
        let lat2 = second.latitude * .pi / 180
        let deltaLongitude = (second.longitude - first.longitude) * .pi / 180
        let y = sin(deltaLongitude) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLongitude)
        return Float((atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360))
    }

    private static func bearingDeltaDegrees(_ first: Float, _ second: Float) -> Float {
        let delta = abs(first - second).truncatingRemainder(dividingBy: 360)
        return min(delta, 360 - delta)
    }

    private static let earthRadiusMeters = 6_371_000.0
    private static let normalWindowMillis: Int64 = 12_000
    private static let degradedWindowMillis: Int64 = 24_000
    private static let maximumWindowSamples = 16
    private static let maxObservedGapMillis: Int64 = 15_000
    private static let poorAccuracyMeters: Float = 25
    private static let minimumCoherentDisplacementMeters: Float = 4
    private static let minimumPathStraightness: Float = 0.55
    private static let minimumCoordinateEvidenceSamples = 3
    private static let minimumCoordinateEvidenceMillis: Int64 = 4_000
    private static let stepRecencyMillis: Int64 = 3_000
    private static let motionMovingEnergy: Float = 0.18
    private static let turnDegrees: Float = 25
    private static let minimumTurnLegStraightness = 0.70
    private static let defaultWalkStrideMeters: Float = 0.72
    private static let defaultRunStrideMeters: Float = 1.05
    private static let minimumStrideMeters: Float = 0.35
    private static let maximumStrideMeters: Float = 1.50
    private static let minimumCalibrationSteps: Int64 = 50
    private static let maximumCalibrationSteps: Int64 = 200
    private static let minimumCalibrationDistanceMeters = 30.0
    private static let maximumCalibrationAccuracyMeters: Float = 15
    private static let calibrationUncertaintyMultiplier: Float = 4
    private static let maximumCalibrationCandidates = 7
    private static let maximumPlausibleStepHz = 4.0
    private static let stepDeltaJitterAllowance: Int64 = 2
}

private nonisolated extension TrackingV2Sample {
    var point: TrackingV2Point { TrackingV2Point(latitude: latitude, longitude: longitude) }

    func with(persona: RidePersona) -> TrackingV2Sample {
        TrackingV2Sample(
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracyMeters: horizontalAccuracyMeters,
            elapsedRealtimeMillis: elapsedRealtimeMillis,
            gpsSpeedMetersPerSecond: gpsSpeedMetersPerSecond,
            gpsSpeedAccuracyMetersPerSecond: gpsSpeedAccuracyMetersPerSecond,
            motionEnergyMetersPerSecondSquared: motionEnergyMetersPerSecondSquared,
            motionSampleAgeMillis: motionSampleAgeMillis,
            cumulativeStepCount: cumulativeStepCount,
            stepAgeMillis: stepAgeMillis,
            stepCadenceHz: stepCadenceHz,
            persona: persona,
            powerMode: powerMode
        )
    }
}

private nonisolated extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
