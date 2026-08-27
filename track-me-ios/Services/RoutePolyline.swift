import CoreLocation
import Foundation

/// TASK-246: the History card's route shape, stored on the ride row.
///
/// 1.8.4 drew each card's route live from `ride.points`. 1.8.5 made the list a projection that
/// keeps route points out of the fetch — right for scrolling a long history, but it left the card
/// with nothing to draw, so every ride fell back to one generic glyph. The shape now travels on the
/// row as a bounded encoded polyline, which keeps the projection intact and gives the card its
/// pixels back.
///
/// The encoding is Google's polyline algorithm, the same one Android stores through `PolyUtil`.
/// Nothing syncs these strings between platforms today; matching the format is so that a shape
/// dumped from one is readable by the other when diagnosing, and so neither side invents a private
/// format that later has to be reconciled.
nonisolated enum RoutePolyline {
    /// Matches Android's `DASHBOARD_ROUTE_POLYLINE_POINTS`. Forty points is far more than a 52pt
    /// tile can resolve, and it keeps the stored string short enough to sit on every ride row.
    static let maxPoints = 40

    /// Builds the stored shape for a ride. `nil` when there is nothing drawable, which is the same
    /// signal the History card treats as "fall back to the glyph".
    static func encoded(from points: [GPSPoint]) -> String? {
        guard points.count >= 2 else { return nil }
        let ordered = points.sorted { $0.timestamp < $1.timestamp }
        let sampled = HomeDashboardWorker.downsample(
            ordered.map { HomeDashboardRoutePoint(latitude: $0.latitude, longitude: $0.longitude) },
            limit: maxPoints
        )
        guard sampled.count >= 2 else { return nil }
        return encode(sampled)
    }

    static func encode(_ points: [HomeDashboardRoutePoint]) -> String {
        var output = ""
        var previousLatitude = 0
        var previousLongitude = 0
        for point in points {
            let latitude = scaled(point.latitude)
            let longitude = scaled(point.longitude)
            output += chunk(latitude - previousLatitude)
            output += chunk(longitude - previousLongitude)
            previousLatitude = latitude
            previousLongitude = longitude
        }
        return output
    }

    /// Returns an empty array rather than throwing on a malformed string. A ride row is persisted
    /// data an older build could have written, and a thumbnail is not worth taking the list down
    /// for — an unreadable shape falls through to the glyph, exactly as a missing one does.
    static func decode(_ encoded: String) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        var index = encoded.startIndex
        var latitude = 0
        var longitude = 0

        while index < encoded.endIndex {
            guard let latitudeDelta = nextValue(encoded, &index) else { return coordinates }
            guard let longitudeDelta = nextValue(encoded, &index) else { return coordinates }
            latitude += latitudeDelta
            longitude += longitudeDelta
            coordinates.append(
                CLLocationCoordinate2D(
                    latitude: Double(latitude) / 1e5,
                    longitude: Double(longitude) / 1e5
                )
            )
        }
        return coordinates
    }

    private static func scaled(_ degrees: Double) -> Int {
        guard degrees.isFinite else { return 0 }
        return Int((degrees * 1e5).rounded())
    }

    private static func chunk(_ delta: Int) -> String {
        // Zig-zag so a negative delta encodes as compactly as a positive one.
        var value = delta < 0 ? ~(delta << 1) : (delta << 1)
        var output = ""
        while value >= 0x20 {
            output.append(Character(UnicodeScalar(UInt8((0x20 | (value & 0x1f)) + 63))))
            value >>= 5
        }
        output.append(Character(UnicodeScalar(UInt8(value + 63))))
        return output
    }

    private static func nextValue(_ encoded: String, _ index: inout String.Index) -> Int? {
        var result = 0
        var shift = 0
        while index < encoded.endIndex {
            guard let ascii = encoded[index].asciiValue, ascii >= 63 else { return nil }
            let byte = Int(ascii) - 63
            index = encoded.index(after: index)
            result |= (byte & 0x1f) << shift
            shift += 5
            if byte < 0x20 {
                return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
            }
            // A continuation that never terminates is malformed; bail rather than shift forever.
            if shift > 30 { return nil }
        }
        return nil
    }
}

/// TASK-246, shvm: "default thumbnail only for less than 50 points or distance is 0 or no points".
///
/// Below this a drawn shape is worse than none. A handful of samples renders as a stray tick that
/// reads like a broken route rather than a short one, and a ride that never moved normalises
/// against a zero span and comes out a dot in the middle of the tile — which is what standing at a
/// light with GPS running produces: thousands of points, no distance. Kept in step with Android's
/// `ROUTE_THUMBNAIL_MIN_POINTS`.
nonisolated enum RouteThumbnailPolicy {
    static let minimumPoints = 50

    static func drawsShape(pointCount: Int, distanceMeters: Double) -> Bool {
        pointCount >= minimumPoints && distanceMeters > 0
    }
}
