import Foundation
import CoreLocation

/**
 * TASK-369: Spatial-temporal dwell detector and continuous trip chaining engine.
 *
 * Solves the critical drop-off gap where riders start a ride but forget to tap "End Ride"
 * upon reaching their destination, leaving recordings running for hours indoors.
 *
 * iOS Core Invariants:
 * 1. Dwell Anchor: When speed drops below stationary threshold (< 3.6 km/h / 1.0 m/s)
 *    for >= 45 seconds, a spatial anchor (lat, lng, anchorTimestamp) is dropped.
 * 2. Bounding Geofence (R <= 75m): Indoor pacing between rooms in an apartment/office
 *    and multipath GPS drift remain within 75m of the anchor. As long as displacement <= 75m,
 *    the rider is classified as DWELLED, suppressing false movement.
 * 3. Auto-End: When dwell duration reaches dwellTimeout (e.g. 5m, 10m, 15m),
 *    triggers AUTO_END. Prunes trailing dwell points back to anchorTimestamp so metrics
 *    (duration, average speed, splits) reflect actual transit.
 * 4. Trip Chaining & Breakout: In standby, when distance > 150m and speed indicates
 *    sustained movement (> 8 km/h cycling, > 20 km/h vehicle, > 4.5 km/h run for >= 20s),
 *    triggers AUTO_START for the next trip.
 */
public enum DwellState: Equatable {
    case activeTracking
    case dwelling
    case tripAutoEnded
    case standbyWaitingForNextTrip
}

public struct DwellEvaluationResult: Equatable {
    public let state: DwellState
    public let shouldAutoEndRide: Bool
    public let autoEndTimestamp: Date?
    public let shouldPruneTrailingPoints: Bool
    public let shouldAutoStartNextRide: Bool
    public let autoStartTimestamp: Date?
    public let dwellAnchorCoordinate: CLLocationCoordinate2D?
    public let currentDwellDuration: TimeInterval
    public let distanceFromAnchorMeters: Double

    public init(
        state: DwellState,
        shouldAutoEndRide: Bool = false,
        autoEndTimestamp: Date? = nil,
        shouldPruneTrailingPoints: Bool = false,
        shouldAutoStartNextRide: Bool = false,
        autoStartTimestamp: Date? = nil,
        dwellAnchorCoordinate: CLLocationCoordinate2D? = nil,
        currentDwellDuration: TimeInterval = 0.0,
        distanceFromAnchorMeters: Double = 0.0
    ) {
        self.state = state
        self.shouldAutoEndRide = shouldAutoEndRide
        self.autoEndTimestamp = autoEndTimestamp
        self.shouldPruneTrailingPoints = shouldPruneTrailingPoints
        self.shouldAutoStartNextRide = shouldAutoStartNextRide
        self.autoStartTimestamp = autoStartTimestamp
        self.dwellAnchorCoordinate = dwellAnchorCoordinate
        self.currentDwellDuration = currentDwellDuration
        self.distanceFromAnchorMeters = distanceFromAnchorMeters
    }

    public static func == (lhs: DwellEvaluationResult, rhs: DwellEvaluationResult) -> Bool {
        return lhs.state == rhs.state &&
            lhs.shouldAutoEndRide == rhs.shouldAutoEndRide &&
            lhs.autoEndTimestamp == rhs.autoEndTimestamp &&
            lhs.shouldPruneTrailingPoints == rhs.shouldPruneTrailingPoints &&
            lhs.shouldAutoStartNextRide == rhs.shouldAutoStartNextRide &&
            lhs.autoStartTimestamp == rhs.autoStartTimestamp &&
            lhs.dwellAnchorCoordinate?.latitude == rhs.dwellAnchorCoordinate?.latitude &&
            lhs.dwellAnchorCoordinate?.longitude == rhs.dwellAnchorCoordinate?.longitude &&
            abs(lhs.currentDwellDuration - rhs.currentDwellDuration) < 0.001 &&
            abs(lhs.distanceFromAnchorMeters - rhs.distanceFromAnchorMeters) < 0.001
    }
}

public final class DwellDetector {
    public var isAutoTripChainingEnabled: Bool
    public var autoEndDwellMinutes: Int
    public var isAutoEndCropDwellEnabled: Bool
    public var stationarySpeedThresholdKmh: Double
    public var dwellAnchorRadiusMeters: Double
    public var breakoutRadiusMeters: Double
    public var breakoutSpeedThresholdKmh: Double
    public var stationaryConfirmationDuration: TimeInterval
    public var breakoutConfirmationDuration: TimeInterval

    public private(set) var state: DwellState = .activeTracking

    private var lowSpeedStartDate: Date?
    private var anchorCoordinate: CLLocationCoordinate2D?
    private var anchorTimestamp: Date?
    private var breakoutStartDate: Date?

    public init(
        isAutoTripChainingEnabled: Bool = false,
        autoEndDwellMinutes: Int = 10,
        isAutoEndCropDwellEnabled: Bool = true,
        stationarySpeedThresholdKmh: Double = 3.6,
        dwellAnchorRadiusMeters: Double = 75.0,
        breakoutRadiusMeters: Double = 150.0,
        breakoutSpeedThresholdKmh: Double = 8.0,
        stationaryConfirmationDuration: TimeInterval = 45.0,
        breakoutConfirmationDuration: TimeInterval = 20.0
    ) {
        self.isAutoTripChainingEnabled = isAutoTripChainingEnabled
        self.autoEndDwellMinutes = autoEndDwellMinutes
        self.isAutoEndCropDwellEnabled = isAutoEndCropDwellEnabled
        self.stationarySpeedThresholdKmh = stationarySpeedThresholdKmh
        self.dwellAnchorRadiusMeters = dwellAnchorRadiusMeters
        self.breakoutRadiusMeters = breakoutRadiusMeters
        self.breakoutSpeedThresholdKmh = breakoutSpeedThresholdKmh
        self.stationaryConfirmationDuration = stationaryConfirmationDuration
        self.breakoutConfirmationDuration = breakoutConfirmationDuration
    }

    public func reset() {
        state = .activeTracking
        lowSpeedStartDate = nil
        anchorCoordinate = nil
        anchorTimestamp = nil
        breakoutStartDate = nil
    }

    public func transitionToStandby(lastAnchorCoordinate: CLLocationCoordinate2D?, now: Date = Date()) {
        state = .standbyWaitingForNextTrip
        anchorCoordinate = lastAnchorCoordinate
        anchorTimestamp = now
        lowSpeedStartDate = nil
        breakoutStartDate = nil
    }

    public func evaluate(
        coordinate: CLLocationCoordinate2D,
        speedKmh: Double,
        now: Date = Date()
    ) -> DwellEvaluationResult {
        guard isAutoTripChainingEnabled else {
            return DwellEvaluationResult(state: .activeTracking)
        }

        let dwellTimeoutSeconds = Double(max(1, min(60, autoEndDwellMinutes))) * 60.0

        switch state {
        case .activeTracking:
            let isLowSpeed = speedKmh <= stationarySpeedThresholdKmh
            if isLowSpeed {
                let lowStart = lowSpeedStartDate ?? now
                if lowSpeedStartDate == nil {
                    lowSpeedStartDate = lowStart
                }
                let lowDuration = now.timeIntervalSince(lowStart)
                if lowDuration >= stationaryConfirmationDuration {
                    state = .dwelling
                    anchorCoordinate = coordinate
                    anchorTimestamp = lowStart
                    return DwellEvaluationResult(
                        state: .dwelling,
                        dwellAnchorCoordinate: coordinate,
                        currentDwellDuration: lowDuration,
                        distanceFromAnchorMeters: 0.0
                    )
                }
            } else {
                lowSpeedStartDate = nil
            }
            return DwellEvaluationResult(state: .activeTracking)

        case .dwelling:
            let aCoord = anchorCoordinate ?? coordinate
            let aTime = anchorTimestamp ?? now
            let dist = Self.computeDistanceMeters(from: aCoord, to: coordinate)

            if dist > dwellAnchorRadiusMeters && speedKmh > stationarySpeedThresholdKmh {
                state = .activeTracking
                lowSpeedStartDate = nil
                anchorCoordinate = nil
                anchorTimestamp = nil
                return DwellEvaluationResult(
                    state: .activeTracking,
                    distanceFromAnchorMeters: dist
                )
            }

            let dwellDuration = now.timeIntervalSince(aTime)
            if dwellDuration >= dwellTimeoutSeconds {
                state = .tripAutoEnded
                return DwellEvaluationResult(
                    state: .tripAutoEnded,
                    shouldAutoEndRide: true,
                    autoEndTimestamp: aTime,
                    shouldPruneTrailingPoints: isAutoEndCropDwellEnabled,
                    dwellAnchorCoordinate: aCoord,
                    currentDwellDuration: dwellDuration,
                    distanceFromAnchorMeters: dist
                )
            }

            return DwellEvaluationResult(
                state: .dwelling,
                dwellAnchorCoordinate: aCoord,
                currentDwellDuration: dwellDuration,
                distanceFromAnchorMeters: dist
            )

        case .tripAutoEnded:
            return DwellEvaluationResult(
                state: .tripAutoEnded,
                autoEndTimestamp: anchorTimestamp
            )

        case .standbyWaitingForNextTrip:
            let aCoord = anchorCoordinate
            let dist: Double
            if let ac = aCoord {
                dist = Self.computeDistanceMeters(from: ac, to: coordinate)
            } else {
                dist = breakoutRadiusMeters + 1.0
            }

            let isMovingAway = dist > breakoutRadiusMeters && speedKmh >= breakoutSpeedThresholdKmh
            if isMovingAway {
                let bStart = breakoutStartDate ?? now
                if breakoutStartDate == nil {
                    breakoutStartDate = bStart
                }
                let bDuration = now.timeIntervalSince(bStart)
                if bDuration >= breakoutConfirmationDuration {
                    state = .activeTracking
                    lowSpeedStartDate = nil
                    anchorCoordinate = nil
                    anchorTimestamp = nil
                    breakoutStartDate = nil
                    return DwellEvaluationResult(
                        state: .activeTracking,
                        shouldAutoStartNextRide: true,
                        autoStartTimestamp: bStart,
                        distanceFromAnchorMeters: dist
                    )
                }
            } else {
                breakoutStartDate = nil
            }

            return DwellEvaluationResult(
                state: .standbyWaitingForNextTrip,
                dwellAnchorCoordinate: aCoord,
                distanceFromAnchorMeters: dist
            )
        }
    }

    public static func computeDistanceMeters(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let loc1 = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let loc2 = CLLocation(latitude: to.latitude, longitude: to.longitude)
        return loc1.distance(from: loc2)
    }
}
