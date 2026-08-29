import SwiftUI
import CoreLocation

struct RoutePreviewThumbnail: View {
    let points: [GPSPoint]
    let previewSize: CGSize
    let scrubIndex: Int?

    init(
        points: [GPSPoint],
        size: CGSize = CGSize(width: 80, height: 60),
        scrubIndex: Int? = nil
    ) {
        self.points = points
        self.previewSize = size
        self.scrubIndex = scrubIndex
    }
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.12))
            
            if points.count >= 2 {
                Canvas { context, size in
                    let coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                    
                    guard let first = coordinates.first else { return }
                    var minLat = first.latitude
                    var maxLat = first.latitude
                    var minLon = first.longitude
                    var maxLon = first.longitude
                    
                    for coord in coordinates {
                        minLat = min(minLat, coord.latitude)
                        maxLat = max(maxLat, coord.latitude)
                        minLon = min(minLon, coord.longitude)
                        maxLon = max(maxLon, coord.longitude)
                    }
                    
                    let latDelta = max(maxLat - minLat, 0.0001)
                    let lonDelta = max(maxLon - minLon, 0.0001)
                    
                    let paddingX = size.width * 0.12
                    let paddingY = size.height * 0.12
                    let drawWidth = size.width - (paddingX * 2)
                    let drawHeight = size.height - (paddingY * 2)
                    
                    var path = Path()
                    for (index, coord) in coordinates.enumerated() {
                        let normalizedX = CGFloat((coord.longitude - minLon) / lonDelta)
                        // Invert Y because screen Y goes down
                        let normalizedY = CGFloat(1.0 - (coord.latitude - minLat) / latDelta)
                        
                        let point = CGPoint(
                            x: paddingX + normalizedX * drawWidth,
                            y: paddingY + normalizedY * drawHeight
                        )
                        
                        if index == 0 {
                            path.move(to: point)
                        } else {
                            path.addLine(to: point)
                        }
                    }
                    
                    context.stroke(
                        path,
                        with: .color(.blue),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                    )

                    if let scrubIndex, coordinates.indices.contains(scrubIndex) {
                        let coordinate = coordinates[scrubIndex]
                        let normalizedX = CGFloat((coordinate.longitude - minLon) / lonDelta)
                        let normalizedY = CGFloat(1.0 - (coordinate.latitude - minLat) / latDelta)
                        let marker = CGPoint(
                            x: paddingX + normalizedX * drawWidth,
                            y: paddingY + normalizedY * drawHeight
                        )
                        context.fill(
                            Path(ellipseIn: CGRect(x: marker.x - 7, y: marker.y - 7, width: 14, height: 14)),
                            with: .color(.white)
                        )
                        context.fill(
                            Path(ellipseIn: CGRect(x: marker.x - 4.5, y: marker.y - 4.5, width: 9, height: 9)),
                            with: .color(BrandColor.primary)
                        )
                    }
                }
            } else {
                Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                    .foregroundColor(.blue.opacity(0.6))
                    .font(.system(size: 20))
            }
        }
        .frame(width: previewSize.width, height: previewSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// TASK-246: the History card's thumbnail, drawn from the shape stored on the ride row.
///
/// Separate from `RoutePreviewThumbnail` above, which takes `[GPSPoint]` and is right where the
/// points are already in hand (Ride Detail, the onboarding demo). This one exists so the History
/// list can draw a real route without the projection ever fetching points — the constraint that
/// made 1.8.5 fall back to one generic glyph for every ride.
struct RouteThumbnail: View {
    let routePolyline: String?
    let pointCount: Int
    let distanceMeters: Double

    private var coordinates: [CLLocationCoordinate2D] {
        guard RouteThumbnailPolicy.drawsShape(pointCount: pointCount, distanceMeters: distanceMeters),
              let routePolyline, !routePolyline.isEmpty else { return [] }
        return RoutePolyline.decode(routePolyline)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(uiColor: .tertiarySystemFill))

            let route = coordinates
            if route.count >= 2 {
                Canvas { context, size in
                    var minLat = route[0].latitude, maxLat = route[0].latitude
                    var minLon = route[0].longitude, maxLon = route[0].longitude
                    for coordinate in route {
                        minLat = min(minLat, coordinate.latitude)
                        maxLat = max(maxLat, coordinate.latitude)
                        minLon = min(minLon, coordinate.longitude)
                        maxLon = max(maxLon, coordinate.longitude)
                    }
                    // A ride that barely moved has no span to normalise against; the floor keeps it
                    // a mark in the middle rather than a divide-by-zero.
                    let latSpan = max(maxLat - minLat, 0.00001)
                    let lonSpan = max(maxLon - minLon, 0.00001)

                    let inset: CGFloat = 6
                    let drawWidth = max(size.width - inset * 2, 1)
                    let drawHeight = max(size.height - inset * 2, 1)

                    var path = Path()
                    for (index, coordinate) in route.enumerated() {
                        let x = inset + CGFloat((coordinate.longitude - minLon) / lonSpan) * drawWidth
                        // Screen Y grows downward, so latitude inverts.
                        let y = inset + CGFloat(1 - (coordinate.latitude - minLat) / latSpan) * drawHeight
                        let point = CGPoint(x: x, y: y)
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    context.stroke(
                        path,
                        with: .color(BrandColor.primary),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                    )
                }
            } else {
                Image(systemName: pointCount > 0
                      ? "point.topleft.down.to.point.bottomright.curvepath"
                      : "location.slash")
                    .font(.title3)
                    .foregroundStyle(BrandColor.primary)
            }
        }
    }
}
