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
    var sampleCount = 0
    var missingSpeedCount = 0
    var degradedSampleCount = 0
    var rejectedOutlierCount = 0
    var stepDistanceMeters = 0.0
    var coordinateDistanceMeters = 0.0
    var rawStepDistanceMeters = 0.0
    var calibratedStepDistanceMeters = 0.0
    var detectedStepCount: Int64 = 0
    var discardedImplausibleStepCount: Int64 = 0
    var strideLengthMeters: Float = 0.72
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
        let motionSaysMoving: Bool
        let stepsRecent: Bool
    }

    private var window: [TrackingV2Sample] = []
    private var routeSegments: [[TrackingV2Point]] = []
    private var hybridCommittedDistanceMeters = 0.0
    private var hybridBridgeStepCount: Int64 = 0
    private var coordinateDistanceMeters = 0.0
    private var detectedStepCount: Int64 = 0
    private var discardedImplausibleStepCount: Int64 = 0
    private var sampleCount = 0
    private var missingSpeedCount = 0
    private var degradedSampleCount = 0
    private var rejectedOutlierCount = 0
    private var lastSample: TrackingV2Sample?
    private var lastStepCount: Int64?
    private var lastCoordinatePoint: TrackingV2Point?
    private var lastCoordinateTimeMillis: Int64?
    private var lastRoutePoint: TrackingV2Point?
    private var lastRouteTimeMillis: Int64?
    private var pendingRouteDistanceMeters = 0.0
    private var stationaryCandidateSinceMillis: Int64?
    private var strideLengthMeters: Float = TrackingV2Estimator.defaultWalkStrideMeters
    private var lastSnapshot = TrackingV2Snapshot()

    func reset(persona: RidePersona = .auto) {
        window.removeAll(keepingCapacity: false)
        routeSegments.removeAll(keepingCapacity: false)
        hybridCommittedDistanceMeters = 0
        hybridBridgeStepCount = 0
        coordinateDistanceMeters = 0
        detectedStepCount = 0
        discardedImplausibleStepCount = 0
        sampleCount = 0
        missingSpeedCount = 0
        degradedSampleCount = 0
        rejectedOutlierCount = 0
        lastSample = nil
        lastStepCount = nil
        lastCoordinatePoint = nil
        lastCoordinateTimeMillis = nil
        lastRoutePoint = nil
        lastRouteTimeMillis = nil
        pendingRouteDistanceMeters = 0
        stationaryCandidateSinceMillis = nil
        strideLengthMeters = defaultStride(for: persona)
        lastSnapshot = TrackingV2Snapshot(strideLengthMeters: strideLengthMeters)
    }

    /// Manual pause/resume and unobserved gaps split geometry and reset every distance anchor.
    func markDiscontinuity() {
        freezeOpenStepBridge()
        window.removeAll(keepingCapacity: false)
        lastSample = nil
        lastCoordinatePoint = nil
        lastCoordinateTimeMillis = nil
        lastRoutePoint = nil
        lastRouteTimeMillis = nil
        pendingRouteDistanceMeters = 0
        stationaryCandidateSinceMillis = nil
    }

    @discardableResult
    func add(_ sample: TrackingV2Sample) -> TrackingV2Snapshot {
        if let previous = lastSample, sample.elapsedRealtimeMillis <= previous.elapsedRealtimeMillis {
            rejectedOutlierCount += 1
            return publish(sample, state: .gpsDegraded, speed: 0)
        }

        sampleCount += 1
        if sample.gpsSpeedMetersPerSecond == nil { missingSpeedCount += 1 }
        let degraded = isDegraded(sample)
        if degraded { degradedSampleCount += 1 }

        guard let previous = lastSample else {
            window.append(sample)
            lastSample = sample
            lastStepCount = sample.cumulativeStepCount
            return publish(
                sample,
                state: degraded ? .gpsDegraded : .unknown,
                speed: sample.gpsSpeedMetersPerSecond ?? 0
            )
        }

        let deltaMillis = sample.elapsedRealtimeMillis - previous.elapsedRealtimeMillis
        if deltaMillis > Self.maxObservedGapMillis {
            markDiscontinuity()
            window.append(sample)
            lastSample = sample
            lastStepCount = sample.cumulativeStepCount
            return publish(sample, state: .gpsDegraded, speed: sample.gpsSpeedMetersPerSecond ?? 0)
        }

        window.append(sample)
        pruneWindow(for: sample)
        let evidence = movementEvidence(for: sample)
        let admittedSteps = stepDelta(from: previous, to: sample)
        let state = classify(sample, evidence: evidence, stepDelta: admittedSteps)
        let speed = fusedSpeed(sample, evidence: evidence, stepDelta: admittedSteps)

        if state == .moving {
            let pedestrian = isPedestrian(sample.persona)
            let coordinateReady = window.count >= minimumCoordinateWindowSize(for: sample.powerMode)
                && (evidence.coherentDisplacement || evidence.gpsSaysMoving)
            let admittedCoordinateMeters = coordinateReady ? admitCoordinateDistance(sample.point, sample: sample) : 0

            if pedestrian, sample.cumulativeStepCount != nil {
                hybridBridgeStepCount += admittedSteps
                if admittedCoordinateMeters > 0 {
                    hybridCommittedDistanceMeters += admittedCoordinateMeters
                    hybridBridgeStepCount = 0
                }
                appendRoutePoint(sample.point, sample: sample)
            } else if admittedCoordinateMeters > 0 {
                hybridCommittedDistanceMeters += admittedCoordinateMeters
                appendRoutePoint(sample.point, sample: sample)
            }
        } else if state == .stationary {
            freezeOpenStepBridge()
            lastCoordinatePoint = sample.point
            lastCoordinateTimeMillis = sample.elapsedRealtimeMillis
        }

        lastSample = sample
        if let steps = sample.cumulativeStepCount { lastStepCount = steps }
        return publish(sample, state: state, speed: speed)
    }

    func finish() -> TrackingV2Snapshot {
        lastSnapshot.isPostProcessed = true
        return lastSnapshot
    }

    func snapshot() -> TrackingV2Snapshot { lastSnapshot }

    private func movementEvidence(for sample: TrackingV2Sample) -> Evidence {
        guard let first = window.first else {
            return Evidence(coordinateSpeedMetersPerSecond: 0, coherentDisplacement: false,
                            reliableGpsSpeed: false, gpsSaysMoving: false, motionFresh: false,
                            motionSaysMoving: false, stepsRecent: false)
        }
        let elapsedSeconds = max(0.001, Double(sample.elapsedRealtimeMillis - first.elapsedRealtimeMillis) / 1_000)
        let coordinateDistance = Self.haversineMeters(first.point, sample.point)
        let windowPath = zip(window, window.dropFirst()).reduce(0.0) { partial, pair in
            partial + Self.haversineMeters(pair.0.point, pair.1.point)
        }
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

        let reliableGpsSpeed: Bool
        if let speed = sample.gpsSpeedMetersPerSecond, speed.isFinite, speed >= 0 {
            if let accuracy = sample.gpsSpeedAccuracyMetersPerSecond {
                reliableGpsSpeed = accuracy <= max(0.8, speed * 0.6)
            } else {
                reliableGpsSpeed = sample.horizontalAccuracyMeters <= 15
            }
        } else {
            reliableGpsSpeed = false
        }
        let gpsSaysMoving = reliableGpsSpeed
            && (sample.gpsSpeedMetersPerSecond ?? 0) >= movementSpeedThreshold(for: sample.persona)
        let freshnessLimit: Int64 = sample.powerMode == .normal ? 1_500 : 3_000
        let motionFresh = sample.motionSampleAgeMillis.map { (0...freshnessLimit).contains($0) } ?? false
        let motionSaysMoving = motionFresh
            && (sample.motionEnergyMetersPerSecondSquared ?? 0) >= Self.motionMovingEnergy
        let stepsRecent = sample.stepAgeMillis.map { (0...Self.stepRecencyMillis).contains($0) } ?? false
        return Evidence(
            coordinateSpeedMetersPerSecond: coordinateSpeed,
            coherentDisplacement: coherent,
            reliableGpsSpeed: reliableGpsSpeed,
            gpsSaysMoving: gpsSaysMoving,
            motionFresh: motionFresh,
            motionSaysMoving: motionSaysMoving,
            stepsRecent: stepsRecent
        )
    }

    private func classify(
        _ sample: TrackingV2Sample,
        evidence: Evidence,
        stepDelta: Int64
    ) -> TrackingV2MovementState {
        let pedestrianEvidence = stepDelta > 0 || evidence.stepsRecent
        let coherentMovement = evidence.coherentDisplacement
            && evidence.coordinateSpeedMetersPerSecond >= movementSpeedThreshold(for: sample.persona)
        let gpsMovementProved = evidence.gpsSaysMoving
            && (!isPedestrian(sample.persona) || pedestrianEvidence || evidence.motionSaysMoving || coherentMovement)
        let movementProved = pedestrianEvidence || gpsMovementProved || coherentMovement
            || (evidence.motionSaysMoving && evidence.coordinateSpeedMetersPerSecond > 0.1)

        if movementProved {
            stationaryCandidateSinceMillis = nil
            return .moving
        }

        let lowFreshMotion = evidence.motionFresh
            && (sample.motionEnergyMetersPerSecondSquared ?? .greatestFiniteMagnitude) <= Self.stationaryEnergy
        let stationaryCandidate = lowFreshMotion && !pedestrianEvidence
            && !evidence.gpsSaysMoving && !evidence.coherentDisplacement
        if stationaryCandidate {
            let since = stationaryCandidateSinceMillis ?? sample.elapsedRealtimeMillis
            stationaryCandidateSinceMillis = since
            return sample.elapsedRealtimeMillis - since >= stationaryDwellMillis(for: sample.persona, powerMode: sample.powerMode)
                ? .stationary
                : .possiblyMoving
        }

        stationaryCandidateSinceMillis = nil
        return isDegraded(sample) ? .gpsDegraded : .unknown
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

    private func admitCoordinateDistance(_ point: TrackingV2Point, sample: TrackingV2Sample) -> Double {
        guard let previousPoint = lastCoordinatePoint, let previousTime = lastCoordinateTimeMillis else {
            let origin = window.first?.point ?? point
            let distance = Self.haversineMeters(origin, point)
            lastCoordinatePoint = point
            lastCoordinateTimeMillis = sample.elapsedRealtimeMillis
            guard isPlausible(distance, sample: sample, previousTimeMillis: window.first?.elapsedRealtimeMillis) else {
                rejectedOutlierCount += 1
                return 0
            }
            coordinateDistanceMeters += distance
            return distance
        }

        let distance = Self.haversineMeters(previousPoint, point)
        guard isPlausible(distance, sample: sample, previousTimeMillis: previousTime) else {
            rejectedOutlierCount += 1
            return 0
        }
        coordinateDistanceMeters += distance
        lastCoordinatePoint = point
        lastCoordinateTimeMillis = sample.elapsedRealtimeMillis
        return distance
    }

    private func appendRoutePoint(_ point: TrackingV2Point, sample: TrackingV2Sample) {
        guard let previousPoint = lastRoutePoint, let previousTime = lastRouteTimeMillis else {
            let origin = window.first?.point ?? point
            var segment = [origin]
            if Self.haversineMeters(origin, point) >= 0.5 { segment.append(point) }
            routeSegments.append(segment)
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
        if pendingRouteDistanceMeters >= threshold {
            if routeSegments.isEmpty { routeSegments.append([previousPoint]) }
            routeSegments[routeSegments.count - 1].append(point)
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
        lastSnapshot = TrackingV2Snapshot(
            distanceMeters: hybridDistance,
            currentSpeedMetersPerSecond: max(0, speed),
            movementState: state,
            routeSegments: routeSegments,
            sampleCount: sampleCount,
            missingSpeedCount: missingSpeedCount,
            degradedSampleCount: degradedSampleCount,
            rejectedOutlierCount: rejectedOutlierCount,
            stepDistanceMeters: calibratedStepDistance,
            coordinateDistanceMeters: coordinateDistanceMeters,
            rawStepDistanceMeters: rawStepDistance,
            calibratedStepDistanceMeters: calibratedStepDistance,
            detectedStepCount: detectedStepCount,
            discardedImplausibleStepCount: discardedImplausibleStepCount,
            strideLengthMeters: strideLengthMeters,
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
        sample.powerMode != .normal || sample.horizontalAccuracyMeters > 25
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

    static func haversineMeters(_ first: TrackingV2Point, _ second: TrackingV2Point) -> Double {
        let lat1 = first.latitude * .pi / 180
        let lat2 = second.latitude * .pi / 180
        let deltaLat = lat2 - lat1
        let deltaLon = (second.longitude - first.longitude) * .pi / 180
        let h = sin(deltaLat / 2) * sin(deltaLat / 2)
            + cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        return 2 * Self.earthRadiusMeters * asin(sqrt(h.clamped(to: 0...1)))
    }

    private static let earthRadiusMeters = 6_371_000.0
    private static let normalWindowMillis: Int64 = 12_000
    private static let degradedWindowMillis: Int64 = 24_000
    private static let maximumWindowSamples = 16
    private static let maxObservedGapMillis: Int64 = 15_000
    private static let minimumCoherentDisplacementMeters: Float = 4
    private static let minimumPathStraightness: Float = 0.55
    private static let minimumCoordinateEvidenceSamples = 3
    private static let minimumCoordinateEvidenceMillis: Int64 = 4_000
    private static let stepRecencyMillis: Int64 = 3_000
    private static let motionMovingEnergy: Float = 0.18
    private static let stationaryEnergy: Float = 0.10
    private static let defaultWalkStrideMeters: Float = 0.72
    private static let defaultRunStrideMeters: Float = 1.05
    private static let maximumPlausibleStepHz = 4.0
    private static let stepDeltaJitterAllowance: Int64 = 2
}

private nonisolated extension TrackingV2Sample {
    var point: TrackingV2Point { TrackingV2Point(latitude: latitude, longitude: longitude) }
}

private nonisolated extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
