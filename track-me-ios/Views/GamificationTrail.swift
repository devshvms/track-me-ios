import CoreGraphics
import Foundation

/// TASK-276: the pure geometry and state behind the My Progress trail.
///
/// Kept out of the view so the parts that can be wrong — where the marker sits, which level a node
/// represents, which side of the path has room for a card — are testable without a simulator.
///
/// **The curve maths is hand-rolled rather than delegated to the platform's path measurement, for
/// the same reason it is on Android.** The first Android version called `PathMeasure`, which is
/// stubbed to zero in plain JVM unit tests: the geometry tests passed vacuously against an empty
/// path while claiming to prove the marker was in the right place. Extracting geometry to make it
/// testable and then measuring it with something untestable defeats the extraction. Sixty lines of
/// Bézier arithmetic is the smaller price, and it keeps both platforms on identical numbers.
enum GamificationTrail {

    /// Design-space bounds. The view scales this to whatever box it is given.
    static let width: CGFloat = 300
    static let height: CGFloat = 430

    enum NodeState: Equatable, Sendable { case passed, current, ahead }

    struct Node: Equatable, Sendable {
        let levelIndex: Int
        let levelId: String
        let position: CGPoint
        let state: NodeState
        /// True when there is room to the right; false means the card belongs on the left.
        let cardOnRight: Bool
    }

    private struct Cubic {
        let p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint
        func at(_ t: CGFloat) -> CGPoint {
            let u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
            return CGPoint(
                x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                y: a * p0.y + b * p1.y + c * p2.y + d * p3.y
            )
        }
    }

    /// A serpentine climb, drawn bottom-left to top-left. It alternates sides deliberately: that is
    /// what leaves a clear column beside every waypoint for its card, and it is why the screen needs
    /// no extra vertical room to explain a level.
    private static let segments: [Cubic] = [
        Cubic(p0: CGPoint(x: 62, y: 404), p1: CGPoint(x: 62, y: 368),
              p2: CGPoint(x: 238, y: 364), p3: CGPoint(x: 238, y: 322)),
        Cubic(p0: CGPoint(x: 238, y: 322), p1: CGPoint(x: 238, y: 280),
              p2: CGPoint(x: 62, y: 276), p3: CGPoint(x: 62, y: 234)),
        Cubic(p0: CGPoint(x: 62, y: 234), p1: CGPoint(x: 62, y: 192),
              p2: CGPoint(x: 238, y: 188), p3: CGPoint(x: 238, y: 146)),
        Cubic(p0: CGPoint(x: 238, y: 146), p1: CGPoint(x: 238, y: 104),
              p2: CGPoint(x: 62, y: 100), p3: CGPoint(x: 62, y: 58)),
    ]

    private static let stepsPerSegment = 64

    /// Cumulative arc length, sampled once. 64 steps per segment is well under a pixel of error.
    private static let table: [(length: CGFloat, point: CGPoint)] = {
        var points: [(CGFloat, CGPoint)] = []
        var length: CGFloat = 0
        var previous = segments[0].p0
        points.append((0, previous))
        for segment in segments {
            for step in 1...stepsPerSegment {
                let point = segment.at(CGFloat(step) / CGFloat(stepsPerSegment))
                length += hypot(point.x - previous.x, point.y - previous.y)
                points.append((length, point))
                previous = point
            }
        }
        return points
    }()

    static var totalLength: CGFloat { table.last?.length ?? 0 }

    /// The point at a fraction of the way along the trail, interpolated between samples.
    static func point(at fraction: CGFloat) -> CGPoint {
        let target = min(max(fraction, 0), 1) * totalLength
        let index = table.firstIndex { $0.length >= target } ?? table.count - 1
        let safe = max(index, 1)
        let before = table[safe - 1], after = table[safe]
        let span = after.length - before.length
        let t = span <= 0 ? 0 : (target - before.length) / span
        return CGPoint(
            x: before.point.x + (after.point.x - before.point.x) * t,
            y: before.point.y + (after.point.y - before.point.y) * t
        )
    }

    /// Levels are spaced evenly along the drawn line rather than by threshold, because the
    /// thresholds grow by a factor of 75 from first to last and a proportional trail would put five
    /// levels in the bottom eighth of it.
    static func fraction(forLevel levelIndex: Int) -> CGFloat {
        let last = GamificationEngine.levels.count - 1
        guard last > 0 else { return 0 }
        return CGFloat(levelIndex) / CGFloat(last)
    }

    static func levelIndex(for snapshot: GamificationSnapshot) -> Int {
        max(GamificationEngine.levels.firstIndex { $0.id == snapshot.currentLevelId } ?? 0, 0)
    }

    /// Progress through the current level, 0...1.
    ///
    /// A non-positive denominator is complete only at the maximum level. Anywhere else it means the
    /// snapshot is malformed, and returning 1 there would draw a finished trail — the single most
    /// misleading thing this screen could say, and indistinguishable from genuine completion.
    static func progressWithinLevel(_ snapshot: GamificationSnapshot) -> CGFloat {
        guard snapshot.progressDenominatorMinutes > 0 else {
            return levelIndex(for: snapshot) == GamificationEngine.levels.count - 1 ? 1 : 0
        }
        let raw = Double(snapshot.progressNumeratorMinutes) / Double(snapshot.progressDenominatorMinutes)
        return CGFloat(min(max(raw, 0), 1))
    }

    /// Where the rider stands: their level's waypoint, plus their progress through that level
    /// interpolated toward the next. This is the single progress encoding on the screen — the radial
    /// version had an arc for within-level and a ring for across-level, both circular and
    /// concentric, and the eye had to reconcile them.
    static func markerFraction(_ snapshot: GamificationSnapshot) -> CGFloat {
        let index = levelIndex(for: snapshot)
        let here = fraction(forLevel: index)
        let next = fraction(forLevel: min(index + 1, GamificationEngine.levels.count - 1))
        return min(max(here + progressWithinLevel(snapshot) * (next - here), 0), 1)
    }

    static func markerPosition(_ snapshot: GamificationSnapshot) -> CGPoint {
        point(at: markerFraction(snapshot))
    }

    /// Waypoints in level order, positioned on the trail and tagged with their state.
    static func nodes(_ snapshot: GamificationSnapshot) -> [Node] {
        let current = levelIndex(for: snapshot)
        return GamificationEngine.levels.enumerated().map { index, level in
            let position = point(at: fraction(forLevel: index))
            return Node(
                levelIndex: index,
                levelId: level.id,
                position: position,
                state: index < current ? .passed : (index == current ? .current : .ahead),
                cardOnRight: position.x < width / 2
            )
        }
    }
}
