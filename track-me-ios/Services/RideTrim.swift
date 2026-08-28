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
