import Charts
import SwiftUI

private struct NormalizedMetricPoint: Identifiable {
    let id: Int
    let timestamp: Date
    let speedNormalized: Double
    let altitudeNormalized: Double
    /// Metres per second. NOT km/h — `UnitFormatter.speed(mps:)` does that conversion.
    let rawSpeedMetersPerSecond: Double
    let rawAltitude: Double
}

/// Reusable speed/elevation chart shared by ride detail and the onboarding history demo.
struct CombinedMetricLineChart: View {
    static var speedSeriesName: String { LocalizationHelper.localized("Speed") }
    static var altitudeSeriesName: String { LocalizationHelper.localized("Altitude") }

    let points: [GPSPoint]
    let scrubIndex: Int?

    @ObservedObject private var unitSettings = UnitSettings.shared

    private var sortedPoints: [GPSPoint] {
        points.sorted { $0.timestamp < $1.timestamp }
    }

    private var normalizedPoints: [NormalizedMetricPoint] {
        let points = sortedPoints
        guard !points.isEmpty else { return [] }

        let speeds = points.map { $0.speed * 3.6 }
        let altitudes = points.map(\.altitude)
        let rawMinSpeed = speeds.min() ?? 0
        let rawMaxSpeed = speeds.max() ?? 0
        let speedRange = rawMaxSpeed > rawMinSpeed ? rawMaxSpeed - rawMinSpeed : 1
        let minSpeed = rawMinSpeed - speedRange * 0.1
        let maxSpeed = rawMaxSpeed + speedRange * 0.1
        let rawMinAltitude = altitudes.min() ?? 0
        let rawMaxAltitude = altitudes.max() ?? 0
        let altitudeRange = rawMaxAltitude > rawMinAltitude ? rawMaxAltitude - rawMinAltitude : 1
        let minAltitude = rawMinAltitude - altitudeRange * 0.1
        let maxAltitude = rawMaxAltitude + altitudeRange * 0.1

        return points.enumerated().map { index, point in
            NormalizedMetricPoint(
                id: index,
                timestamp: point.timestamp,
                speedNormalized: (speeds[index] - minSpeed) / (maxSpeed - minSpeed),
                altitudeNormalized: (altitudes[index] - minAltitude) / (maxAltitude - minAltitude),
                // Metres per second, deliberately: `speeds` above is already km/h, and the
                // annotation hands this to `UnitFormatter.speed(mps:)`, which converts again.
                // Passing the km/h value there multiplied speed by 3.6 twice — a bike at 7.6 m/s
                // rendered as "98.2 km/h". The old synthetic fixture topped out at 4.13 m/s, which
                // mis-rendered as a believable 53 km/h, which is why this survived review.
                rawSpeedMetersPerSecond: points[index].speed,
                rawAltitude: point.altitude
            )
        }
    }

    private var chartSamples: [ChartSample] {
        sortedPoints.map {
            ChartSample(
                timestamp: $0.timestamp,
                speedMetersPerSecond: $0.speed,
                altitudeMeters: $0.altitude
            )
        }
    }

    var body: some View {
        let normalizedPoints = normalizedPoints
        let gaps = ChartAccessibility.signalGaps(for: chartSamples)

        Chart {
            // Keep gap bands behind the metric lines and derive them from the same samples used by
            // the VoiceOver summary.
            ForEach(Array(gaps.enumerated()), id: \.offset) { _, gap in
                RectangleMark(
                    xStart: .value("Gap start", gap.start),
                    xEnd: .value("Gap end", gap.end)
                )
                .foregroundStyle(Color.red.opacity(0.30))
            }

            ForEach(normalizedPoints) { point in
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Value", point.speedNormalized)
                )
                .foregroundStyle(by: .value("Metric", Self.speedSeriesName))
                .lineStyle(StrokeStyle(lineWidth: 2))
            }

            ForEach(normalizedPoints) { point in
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Value", point.altitudeNormalized)
                )
                .foregroundStyle(by: .value("Metric", Self.altitudeSeriesName))
                .lineStyle(StrokeStyle(lineWidth: 2))
            }

            if let index = scrubIndex, normalizedPoints.indices.contains(index) {
                let point = normalizedPoints[index]
                RuleMark(x: .value("Selected", point.timestamp))
                    .foregroundStyle(Color.gray.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5]))

                PointMark(
                    x: .value("Selected", point.timestamp),
                    y: .value("Value", point.speedNormalized)
                )
                .foregroundStyle(by: .value("Metric", Self.speedSeriesName))
                .annotation(position: .top, alignment: .center) {
                    Text(UnitFormatter.speed(mps: point.rawSpeedMetersPerSecond, unit: unitSettings.unit))
                        // The chart summary/scrubber remains the primary VoiceOver path; keep these
                        // visual annotations readable without covering the plot.
                        .font(.caption2.bold())
                        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(BrandColor.chartSpeed)
                        .foregroundColor(.white)
                        .cornerRadius(4)
                }

                PointMark(
                    x: .value("Selected", point.timestamp),
                    y: .value("Value", point.altitudeNormalized)
                )
                .foregroundStyle(by: .value("Metric", Self.altitudeSeriesName))
                .annotation(position: .bottom, alignment: .center) {
                    Text(String(format: "%.1f m", point.rawAltitude))
                        .font(.caption2.bold())
                        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(BrandColor.chartAltitude)
                        .foregroundColor(.white)
                        .cornerRadius(4)
                }
            }
        }
        // TASK-241: Swift Charts prints the *series name* in the legend, so a raw "Speed" string
        // stayed English on an otherwise French chart. The name is localized once and used for both
        // the series and the colour scale — they are matched by value, so they cannot be allowed to
        // drift apart or the colours detach from the legend.
        .chartForegroundStyleScale([
            Self.speedSeriesName: BrandColor.chartSpeed,
            Self.altitudeSeriesName: BrandColor.chartAltitude
        ])
        .chartLegend(position: .top, alignment: .leading)
        .frame(height: 200)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .padding()
        .background(Color(UIColor.darkGray))
        .cornerRadius(12)
        // Swift Charts' default per-point audio graph is meaningless with hundreds of points;
        // speak a single summary sentence instead.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            ChartAccessibility.description(points: sortedPoints, unit: unitSettings.unit)
        )
    }
}
