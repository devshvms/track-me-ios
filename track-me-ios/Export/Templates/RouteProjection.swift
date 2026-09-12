import CoreGraphics
import Foundation

/// A point on the route, free of any map framework. The template renderer never sees a `GPSPoint`.
nonisolated struct TemplateCoordinate: Equatable {
    let latitude: Double
    let longitude: Double
}

/// Where a route lands inside a box when there is **no map under it** — the VECTOR mode of the export
/// templates (SCOPE_1.8.9 §4). The exact twin of Android's `RouteProjection`, so a ride exported on
/// either phone has the same shape.
///
/// 1. **One scale for both axes**, so a route that is not the frame's shape is not stretched into it.
/// 2. **Web-Mercator, not raw degrees.** A degree of longitude is `cos(latitude)` of a degree of
///    latitude on the ground; raw degrees stretch every route east–west by `1/cos(lat)`.
///
/// **Never use this over a map snapshot** — `EXPORT_SHARE_CONTRACTS.md` "Never re-derive the map
/// projection": over a map, positions come from `MKMapSnapshotter.Snapshot.point(for:)`.
nonisolated struct RouteProjection {
    private let minX: Double
    private let maxY: Double
    private let scale: Double
    private let offsetX: CGFloat
    private let offsetY: CGFloat

    func project(_ coordinate: TemplateCoordinate) -> CGPoint {
        CGPoint(
            x: offsetX + CGFloat((Self.mercatorX(coordinate.longitude) - minX) * scale),
            y: offsetY + CGFloat((maxY - Self.mercatorY(coordinate.latitude)) * scale)
        )
    }

    func project(_ coordinates: [TemplateCoordinate]) -> [CGPoint] { coordinates.map(project) }

    /// Fits every coordinate inside `box`, centred, one scale for both axes. Nil when there is
    /// nothing to fit or nowhere to fit it. A route with no extent on an axis constrains nothing on it.
    static func fit(_ coordinates: [TemplateCoordinate], in box: CGRect) -> RouteProjection? {
        guard !coordinates.isEmpty, box.width > 0, box.height > 0 else { return nil }
        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        for coordinate in coordinates {
            let x = mercatorX(coordinate.longitude)
            let y = mercatorY(coordinate.latitude)
            minX = Swift.min(minX, x); maxX = Swift.max(maxX, x)
            minY = Swift.min(minY, y); maxY = Swift.max(maxY, y)
        }
        let spanX = maxX - minX
        let spanY = maxY - minY
        let scaleX = spanX > epsilon ? Double(box.width) / spanX : .infinity
        let scaleY = spanY > epsilon ? Double(box.height) / spanY : .infinity
        let fitted = Swift.min(scaleX, scaleY)
        let scale = fitted.isFinite ? fitted : 1
        let drawnWidth = CGFloat(spanX * scale)
        let drawnHeight = CGFloat(spanY * scale)
        return RouteProjection(
            minX: minX,
            maxY: maxY,
            scale: scale,
            offsetX: box.minX + (box.width - drawnWidth) / 2,
            offsetY: box.minY + (box.height - drawnHeight) / 2
        )
    }

    private static let epsilon = 1e-12
    /// Mercator is undefined at the poles; a corrupt point must not produce infinity.
    private static let maxLatitude = 85.0

    static func mercatorX(_ longitude: Double) -> Double { longitude * .pi / 180 }

    static func mercatorY(_ latitude: Double) -> Double {
        let clamped = Swift.max(-maxLatitude, Swift.min(maxLatitude, latitude)) * .pi / 180
        return log(tan(.pi / 4 + clamped / 2))
    }
}

nonisolated enum TemplateGeometry {
    /// Drops points closer than `minStep` to the last one kept, always keeping both ends. Returns the
    /// kept indices, so a per-point value (pace) can follow the thinned line.
    static func decimate(_ points: [CGPoint], minStep: CGFloat) -> [Int] {
        guard points.count > 2 else { return Array(points.indices) }
        var kept = [0]
        var last = points[0]
        for index in 1..<(points.count - 1) where hypot(points[index].x - last.x, points[index].y - last.y) >= minStep {
            kept.append(index)
            last = points[index]
        }
        kept.append(points.count - 1)
        return kept
    }
}
