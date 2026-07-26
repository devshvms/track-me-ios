import Foundation

/// A minimal, storage-agnostic representation of a charted GPS sample.
///
/// Deliberately free of SwiftData so the accessibility summary can be
/// unit-tested without a live `ModelContext`.
struct ChartSample {
    let timestamp: Date
    let speedMetersPerSecond: Double
    let altitudeMeters: Double
}

/// Builds the VoiceOver summary spoken in place of Swift Charts' default
/// per-point audio graph, which is unusable for a route with hundreds of
/// points.
///
/// Mirrors the Android `buildChartAccessibilityDescription` (commit `e0feadb`):
/// duration, average speed, altitude range, and the number of GPS signal gaps.
enum ChartAccessibility {
    /// Successive samples more than this many seconds apart count as a gap.
    static let gapThresholdSeconds: TimeInterval = 25

    /// Returns the timestamp intervals spanning every GPS signal gap.
    ///
    /// This is the single source of truth for both the spoken gap count and
    /// the visual chart bands. Keeping the helper storage-agnostic makes the
    /// boundary behavior unit-testable without SwiftData or a live chart.
    static func signalGaps(for samples: [ChartSample]) -> [(start: Date, end: Date)] {
        guard samples.count > 1 else { return [] }

        var gaps: [(start: Date, end: Date)] = []
        for index in 1..<samples.count {
            let previous = samples[index - 1].timestamp
            let current = samples[index].timestamp
            if current.timeIntervalSince(previous) > gapThresholdSeconds {
                gaps.append((start: previous, end: current))
            }
        }
        return gaps
    }

    /// Composes the spoken description for a set of samples.
    static func description(for samples: [ChartSample], unit: UnitSystem = .metric) -> String {
        guard let first = samples.first, let last = samples.last else {
            return LocalizationHelper.localized("Speed and altitude chart. No GPS data available.")
        }

        let duration = last.timestamp.timeIntervalSince(first.timestamp)
        let averageSpeedMps = samples.reduce(0) { $0 + $1.speedMetersPerSecond }
            / Double(samples.count)
        let altitudes = samples.map(\.altitudeMeters)
        let minAltitude = altitudes.min() ?? 0
        let maxAltitude = altitudes.max() ?? 0

        let gaps = signalGaps(for: samples).count

        let gapSentence: String
        switch gaps {
        case 0: gapSentence = LocalizationHelper.localized("No GPS signal gaps.")
        case 1: gapSentence = LocalizationHelper.localized("1 GPS signal gap.")
        default: gapSentence = LocalizationHelper.formatted("%@ GPS signal gaps.", String(gaps))
        }

        return LocalizationHelper.formatted(
            "Speed and altitude chart. Duration %@. Average speed %@. Altitude ranges from %@ to %@ meters. %@",
            spokenDuration(duration),
            UnitFormatter.speed(mps: averageSpeedMps, unit: unit),
            String(format: "%.0f", minAltitude),
            String(format: "%.0f", maxAltitude),
            gapSentence
        )
    }

    /// Duration read as words ("2 minutes 5 seconds") rather than a colon-packed
    /// timer string, which VoiceOver mispronounces.
    static func spokenDuration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return LocalizationHelper.formatted("%@ hours %@ minutes", String(hours), String(minutes))
        } else if minutes > 0 {
            return LocalizationHelper.formatted("%@ minutes %@ seconds", String(minutes), String(seconds))
        } else {
            return LocalizationHelper.formatted("%@ seconds", String(seconds))
        }
    }
}

extension ChartAccessibility {
    /// App-facing convenience for drawing gap intervals from SwiftData points.
    static func signalGaps(points: [GPSPoint]) -> [(start: Date, end: Date)] {
        signalGaps(for: points
            .sorted { $0.timestamp < $1.timestamp }
            .map { ChartSample(timestamp: $0.timestamp,
                               speedMetersPerSecond: $0.speed,
                               altitudeMeters: $0.altitude) })
    }

    /// App-facing convenience: maps SwiftData points into samples, sorted by time.
    static func description(points: [GPSPoint], unit: UnitSystem = .metric) -> String {
        let samples = points
            .sorted { $0.timestamp < $1.timestamp }
            .map { ChartSample(timestamp: $0.timestamp,
                               speedMetersPerSecond: $0.speed,
                               altitudeMeters: $0.altitude) }
        return description(for: samples, unit: unit)
    }
}
