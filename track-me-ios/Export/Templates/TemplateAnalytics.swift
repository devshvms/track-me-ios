import Foundation

/// A GPS sample as the templates read it — a value, copied once off the SwiftData model, so drawing a
/// template never touches a model object across actors.
nonisolated struct TemplatePoint: Equatable {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let speed: Double
    let timestamp: Date
    let isPaused: Bool

    var coordinate: TemplateCoordinate { TemplateCoordinate(latitude: latitude, longitude: longitude) }
}

/// One completed (or trailing partial) kilometre or mile. The twin of Android's `RideSplit`.
nonisolated struct RideSplit: Equatable {
    let index: Int
    let distanceMeters: Double
    let movingMillis: Int64
    let isPartial: Bool

    var averageSpeedMps: Double { movingMillis <= 0 ? 0 : distanceMeters / (Double(movingMillis) / 1_000) }
}

/// The data the export templates draw beyond the route itself (SCOPE_1.8.9 §6.1, §6.3) — pace along
/// the line, the elevation band, the split bars and the fastest segment. A faithful port of Android's
/// `TemplateAnalytics.kt` and `RideSplits.kt`, so both phones draw the same picture from the same
/// ride. Every function returns something honest to draw, or nothing.
nonisolated enum TemplateAnalytics {

    /// A ride that held one pace is drawn at the middle of the gradient, not at either end.
    static let flatPaceIntensity: Float = 0.55
    private static let minMovingMps = 0.3
    private static let minSpeedRangeMps = 0.4
    private static let smoothingWindow = 5

    static func haversineMeters(_ a: TemplatePoint, _ b: TemplatePoint) -> Double {
        haversineMeters(a.latitude, a.longitude, b.latitude, b.longitude)
    }

    /// The same formula on bare coordinates, for callers that have no points — `AggregateSelection`
    /// measures between the ends of different rides. One implementation on purpose: both thresholds
    /// in Part 2 are distances, and two haversines that rounded differently would move them.
    static func haversineMeters(_ aLat: Double, _ aLon: Double, _ bLat: Double, _ bLon: Double) -> Double {
        let radius = 6_371_000.0
        let dLat = (bLat - aLat) * .pi / 180
        let dLon = (bLon - aLon) * .pi / 180
        let lat1 = aLat * .pi / 180
        let lat2 = bLat * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return radius * 2 * atan2(sqrt(h), sqrt(1 - h))
    }

    // MARK: - Pace along the line

    /// Per-point pace intensity, 0 = the ride's slow end, 1 = its fast end. Normalised between the
    /// 10th and 90th percentile of moving speed so one GPS spike cannot squash the real ride.
    static func paceIntensities(_ points: [TemplatePoint]) -> [Float] {
        guard !points.isEmpty else { return [] }
        let speeds = points.map { point -> Double in
            point.isPaused || !point.speed.isFinite || point.speed < 0 ? 0 : point.speed
        }
        let smoothed = smooth(speeds)
        let moving = smoothed.filter { $0 > minMovingMps }.sorted()
        guard moving.count >= 2 else { return Array(repeating: flatPaceIntensity, count: points.count) }
        let low = percentile(moving, 0.10)
        let high = percentile(moving, 0.90)
        guard high - low >= minSpeedRangeMps else { return Array(repeating: flatPaceIntensity, count: points.count) }
        return smoothed.map { Float(Swift.max(0, Swift.min(1, ($0 - low) / (high - low)))) }
    }

    // MARK: - Elevation band

    nonisolated struct ElevationProfile: Equatable {
        let heights: [Float]
        let gainMeters: Double
    }

    /// The Instrument's elevation band, or nil when there is nothing honest to plot: fewer than ten
    /// usable altitudes, every altitude exactly zero, or no stored gain. Plotted against at least
    /// 30 m, so a flat ride looks flat (SCOPE_1.8.9 §12 R4).
    static func elevationProfile(
        _ points: [TemplatePoint],
        storedGainMeters: Double?,
        bins: Int = 72,
        distance: (TemplatePoint, TemplatePoint) -> Double = TemplateAnalytics.haversineMeters
    ) -> ElevationProfile? {
        guard let storedGainMeters, bins >= 2 else { return nil }
        let usable = points.filter { $0.altitude.isFinite }.sorted { $0.timestamp < $1.timestamp }
        guard usable.count >= 10, !usable.allSatisfy({ $0.altitude == 0 }) else { return nil }
        let altitudes = smooth(usable.map(\.altitude))
        var cumulative = [0.0]
        for index in 1..<usable.count {
            cumulative.append(cumulative[index - 1] + Swift.max(0, distance(usable[index - 1], usable[index])))
        }
        guard let total = cumulative.last, total > 0,
              let minimum = altitudes.min(), let maximum = altitudes.max() else { return nil }
        let range = Swift.max(maximum - minimum, 30)
        var cursor = 0
        var heights: [Float] = []
        for bin in 0..<bins {
            let target = total * Double(bin) / Double(bins - 1)
            while cursor < cumulative.count - 2 && cumulative[cursor + 1] < target { cursor += 1 }
            let start = cumulative[cursor]
            let end = cumulative[Swift.min(cursor + 1, cumulative.count - 1)]
            let fraction = end > start ? Swift.max(0, Swift.min(1, (target - start) / (end - start))) : 0
            let next = altitudes[Swift.min(cursor + 1, altitudes.count - 1)]
            let altitude = altitudes[cursor] + (next - altitudes[cursor]) * fraction
            heights.append(Float(0.08 + 0.84 * ((altitude - minimum) / range)))
        }
        return ElevationProfile(heights: heights, gainMeters: storedGainMeters)
    }

    // MARK: - Splits

    static func splitUnitMeters(imperial: Bool) -> Double { imperial ? 1_609.344 : 1_000 }

    /// Cuts a ride into per-unit splits, dividing the legs that straddle a boundary in proportion —
    /// the exact rules of Android's `rideSplits`, so the two phones call the same kilometre fastest.
    static func splits(
        _ points: [TemplatePoint],
        imperial: Bool,
        minLegMeters: Double = 3.5,
        distance: (TemplatePoint, TemplatePoint) -> Double = TemplateAnalytics.haversineMeters
    ) -> [RideSplit] {
        guard points.count >= 2 else { return [] }
        let unit = splitUnitMeters(imperial: imperial)
        var result: [RideSplit] = []
        var index = 1
        var distanceIntoSplit = 0.0
        var millisIntoSplit: Int64 = 0
        for i in 1..<points.count {
            let previous = points[i - 1]
            let current = points[i]
            if current.isPaused { continue }
            var legMeters = distance(previous, current)
            if legMeters < minLegMeters { continue }
            var legMillis = Swift.max(0, Int64((current.timestamp.timeIntervalSince(previous.timestamp) * 1_000).rounded()))
            while distanceIntoSplit + legMeters >= unit {
                let remaining = unit - distanceIntoSplit
                let share = legMeters > 0 ? remaining / legMeters : 0
                let taken = Int64(Double(legMillis) * share)
                result.append(RideSplit(index: index, distanceMeters: unit, movingMillis: millisIntoSplit + taken, isPartial: false))
                index += 1
                legMeters -= remaining
                legMillis -= taken
                distanceIntoSplit = 0
                millisIntoSplit = 0
            }
            distanceIntoSplit += legMeters
            millisIntoSplit += legMillis
        }
        if distanceIntoSplit >= minLegMeters {
            result.append(RideSplit(index: index, distanceMeters: distanceIntoSplit, movingMillis: millisIntoSplit, isPartial: true))
        }
        return result
    }

    /// The fastest full split; partials never take the crown.
    static func fastest(_ splits: [RideSplit]) -> RideSplit? {
        splits.filter { !$0.isPartial && $0.averageSpeedMps > 0 }.max { $0.averageSpeedMps < $1.averageSpeedMps }
    }

    nonisolated struct SplitBar: Equatable {
        let heightFraction: Float
        let speedFraction: Float
        let isFastest: Bool
        let isPartial: Bool
    }

    /// Taller is faster; the slowest split still stands at 30 % so it never reads as missing.
    static func splitBars(_ splits: [RideSplit]) -> [SplitBar] {
        let full = splits.filter { !$0.isPartial && $0.averageSpeedMps > 0 }
        guard let slowest = full.map(\.averageSpeedMps).min(), let quickest = full.map(\.averageSpeedMps).max() else { return [] }
        let fastestIndex = fastest(splits)?.index
        let range = quickest - slowest
        return splits.filter { $0.averageSpeedMps > 0 }.map { split in
            let fraction = range < 1e-6 ? 0.6 : Swift.max(0, Swift.min(1, (split.averageSpeedMps - slowest) / range))
            return SplitBar(
                heightFraction: Float(0.3 + 0.7 * fraction),
                speedFraction: Float(fraction),
                isFastest: split.index == fastestIndex && !split.isPartial,
                isPartial: split.isPartial
            )
        }
    }

    /// The fastest full split's coordinates, clipped to the drawn (trimmed) route; nil when there is
    /// none or it lies entirely in a trimmed end. Distance accumulates under `splits`' own rules.
    static func fastestSplitSegment(
        _ points: [TemplatePoint],
        imperial: Bool,
        drawn: [TemplatePoint],
        minLegMeters: Double = 3.5,
        distance: (TemplatePoint, TemplatePoint) -> Double = TemplateAnalytics.haversineMeters
    ) -> [TemplateCoordinate]? {
        guard points.count >= 2, drawn.count >= 2,
              let quickest = fastest(splits(points, imperial: imperial, minLegMeters: minLegMeters, distance: distance)) else { return nil }
        let unit = splitUnitMeters(imperial: imperial)
        let from = Double(quickest.index - 1) * unit
        let to = Double(quickest.index) * unit
        var cumulative = [0.0]
        for index in 1..<points.count {
            let leg = points[index].isPaused ? 0 : distance(points[index - 1], points[index])
            cumulative.append(cumulative[index - 1] + (leg < minLegMeters ? 0 : leg))
        }
        guard let firstReached = cumulative.firstIndex(where: { $0 >= from }) else { return nil }
        let first = firstReached > 0 ? firstReached - 1 : firstReached
        let last = cumulative.firstIndex(where: { $0 >= to }) ?? points.count - 1
        guard last > first else { return nil }
        let visibleFrom = drawn.map(\.timestamp).min()!
        let visibleTo = drawn.map(\.timestamp).max()!
        let segment = points[first...last]
            .filter { $0.timestamp >= visibleFrom && $0.timestamp <= visibleTo }
            .map(\.coordinate)
        return segment.count >= 2 ? segment : nil
    }

    // MARK: - Helpers

    private static func smooth(_ values: [Double]) -> [Double] {
        let half = smoothingWindow / 2
        return values.indices.map { index in
            let slice = values[Swift.max(0, index - half)...Swift.min(values.count - 1, index + half)]
            return slice.reduce(0, +) / Double(slice.count)
        }
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        let rank = fraction * Double(sorted.count - 1)
        let lower = Int(rank)
        let upper = Swift.min(lower + 1, sorted.count - 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (rank - Double(lower))
    }
}
