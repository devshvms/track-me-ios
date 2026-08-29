import CoreLocation
import Foundation

/// The stationary head and tail of a ride, which nobody meant to record.
struct RideTrim: Equatable {
    /// First point worth drawing, inclusive.
    let startIndex: Int
    /// Last point worth drawing, inclusive.
    let endIndex: Int
    let leadingSeconds: TimeInterval
    let trailingSeconds: TimeInterval

    var isTrimmed: Bool { leadingSeconds > 0 || trailingSeconds > 0 }
    var totalTrimmedSeconds: TimeInterval { leadingSeconds + trailingSeconds }
}

/// TASK-253, shvm: a rider starts recording before setting off and forgets to stop after arriving,
/// so the chart ends in a flat line for half an hour and the map carries a blob where they parked.
///
/// **The framing that makes this cheap: we do not need to know *where* a ride ended, only *that* it
/// did.** shvm asked how to detect the destination — geofences, home tags, learned locations — and
/// none of that is needed. Whether the rider has stopped moving is already decided during recording
/// and already written onto every point as `isPaused`.
///
/// **This is a display window, not an edit.** It stores nothing and deletes nothing: it returns a
/// range for the chart and map to draw, so there is no undo to build — the caller simply stops
/// applying it. The stats are deliberately untouched and are already correct: moving duration
/// excludes paused samples, so the forgotten half hour was never in "Duration". It *is* in "Total",
/// correctly, because Total is wall time and the ride really did span it.
///
/// **Only the ends.** A pause at a traffic light is interior and must survive — it is part of the
/// ride, and cutting it would silently teleport the route across a junction.
///
/// Kept in step with Android's `rideTrimWindow`.
enum RideTrimmer {

    /// Two minutes. Below this a flat run is a level crossing or a chat at the gate, and cutting it
    /// would misrepresent the ride; above it, the rider has almost certainly stopped riding.
    /// Deliberately far above any auto-pause stillness threshold: pausing a timer early is cheap and
    /// reversible, hiding a portion of someone's route is neither.
    static let minimumRunSeconds: TimeInterval = 120

    /// 2.5 km/h, Android's cycling pause speed.
    ///
    /// Android picks this per persona from `PersonaAutoPauseConfig`; iOS has no such table, so it
    /// takes the middle value rather than inventing one. The asymmetry is deliberate and worth
    /// knowing: on a walk, iOS trims slightly less eagerly than Android does. `isPaused` carries
    /// most of the decision on both platforms — the speed test is the backstop for a rider who
    /// turned auto-pause off, which is exactly when the platforms would diverge.
    static let defaultPauseSpeedMetersPerSecond: Double = 2.5 / 3.6

    /// Below this there is no shape to trim toward, and the window would be noise.
    private static let minimumPointsToTrim = 4

    static func window(
        for points: [GPSPoint],
        pauseSpeedMetersPerSecond: Double = defaultPauseSpeedMetersPerSecond,
        minimumRunSeconds: TimeInterval = minimumRunSeconds
    ) -> RideTrim {
        let last = points.count - 1
        guard points.count >= minimumPointsToTrim else {
            return RideTrim(startIndex: 0, endIndex: max(last, 0), leadingSeconds: 0, trailingSeconds: 0)
        }

        func stationary(_ point: GPSPoint) -> Bool {
            point.isPaused || point.speed <= pauseSpeedMetersPerSecond
        }

        var start = 0
        while start < last && stationary(points[start]) { start += 1 }

        var end = last
        while end > start && stationary(points[end]) { end -= 1 }

        // Everything was stationary. There is no ride to frame, so draw all of it rather than
        // nothing, and let the reader see that for themselves.
        guard start < end else {
            return RideTrim(startIndex: 0, endIndex: last, leadingSeconds: 0, trailingSeconds: 0)
        }

        let leading = points[start].timestamp.timeIntervalSince(points[0].timestamp)
        let trailing = points[last].timestamp.timeIntervalSince(points[end].timestamp)

        let trimStart = leading >= minimumRunSeconds ? start : 0
        let trimEnd = trailing >= minimumRunSeconds ? end : last

        return RideTrim(
            startIndex: trimStart,
            endIndex: trimEnd,
            leadingSeconds: trimStart > 0 ? leading : 0,
            trailingSeconds: trimEnd < last ? trailing : 0
        )
    }
}

/// TASK-257, shvm: a stretch of a ride that was never recorded.
///
/// Mirrors Android's `RideGaps`. The rule takes **two** signals — a time gap *and* a speed the
/// persona could not have reached — and it is AND, never OR. Time alone would dot a 30-second
/// sampling gap the rider genuinely rode; implied speed alone fires on a single jittery fix, and at
/// 1 Hz one bad fix implies an absurd speed.
///
/// The ceilings are deliberately generous and `auto` takes the most permissive, because the failure
/// directions are not symmetric: a false negative is a cosmetically solid line, while a false
/// positive draws a real part of someone's ride as if we had not recorded it.
///
/// **This governs how a gap is drawn, not whether its distance counts.** A manual pause at walking
/// pace is invisible to a speed rule — that is why the pause now writes a flagged point instead.
enum RideGaps {

    /// Matches Android's `GAP_THRESHOLD_MILLIS` and `ChartAccessibility.gapThresholdSeconds`.
    /// Reused rather than re-picked: two thresholds for one idea drift, and a rider comparing the
    /// "GPS signal gaps" count to the dotted segments should see them agree.
    static let gapThresholdSeconds: TimeInterval = 25

    /// Ceilings, not typical speeds — a cyclist descending touches 80 km/h.
    static func maxPlausibleSpeedMetersPerSecond(for persona: RidePersona) -> Double {
        switch persona {
        case .walk: return 12 / 3.6
        case .run: return 30 / 3.6
        case .cycling: return 80 / 3.6
        case .bikeDrive: return 160 / 3.6
        case .carDrive: return 220 / 3.6
        // Unknown activity: the most permissive, so `auto` never dots a real segment.
        case .auto: return 220 / 3.6
        }
    }

    static func isUnrecordedGap(from previous: GPSPoint, to current: GPSPoint, persona: RidePersona) -> Bool {
        let elapsed = current.timestamp.timeIntervalSince(previous.timestamp)
        guard elapsed > gapThresholdSeconds else { return false }

        let from = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
        let to = CLLocation(latitude: current.latitude, longitude: current.longitude)
        let impliedSpeed = to.distance(from: from) / elapsed
        return impliedSpeed > maxPlausibleSpeedMetersPerSecond(for: persona)
    }

    /// Splits a ride into the runs that were actually recorded.
    ///
    /// The space *between* two consecutive runs is a gap, to be drawn dotted. Returning runs rather
    /// than a per-point flag keeps the renderer honest — it cannot accidentally draw a continuous
    /// path through a gap, because it never holds one.
    static func recordedRuns(_ points: [GPSPoint], persona: RidePersona) -> [[GPSPoint]] {
        guard !points.isEmpty else { return [] }
        var runs: [[GPSPoint]] = []
        var run: [GPSPoint] = []
        var previousRecordedPoint: GPSPoint?

        for point in points {
            if point.isPaused {
                if !run.isEmpty { runs.append(run) }
                run = []
                previousRecordedPoint = nil
                continue
            }

            if let previous = previousRecordedPoint,
               isUnrecordedGap(from: previous, to: point, persona: persona) {
                if !run.isEmpty { runs.append(run) }
                run = []
            }
            run.append(point)
            previousRecordedPoint = point
        }
        if !run.isEmpty { runs.append(run) }
        return runs
    }
}
