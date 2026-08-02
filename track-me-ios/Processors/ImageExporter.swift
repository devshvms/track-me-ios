import Foundation
import MapKit
import UIKit

class ImageExporter {
    /// Renders the supplied presentation points. Callers own sorting and
    /// privacy policy; this renderer never reads a ride's stored points.
    static func generateSnapshot(points: [GPSPoint], size: CGSize = CGSize(width: 800, height: 800), completion: @escaping (UIImage?) -> Void) {
        let sortedPoints = points.sorted { $0.timestamp < $1.timestamp }
        guard !sortedPoints.isEmpty else {
            completion(nil)
            return
        }

        let coordinates = sortedPoints.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        var minLat = coordinates[0].latitude
        var maxLat = minLat
        var minLon = coordinates[0].longitude
        var maxLon = minLon
        for coordinate in coordinates {
            minLat = min(minLat, coordinate.latitude)
            maxLat = max(maxLat, coordinate.latitude)
            minLon = min(minLon, coordinate.longitude)
            maxLon = max(maxLon, coordinate.longitude)
        }

        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: (maxLat - minLat) * 1.5, longitudeDelta: (maxLon - minLon) * 1.5)
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: center, span: span)
        options.size = size
        options.scale = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.scale ?? 2.0

        MKMapSnapshotter(options: options).start { snapshot, error in
            guard let snapshot, error == nil else { completion(nil); return }
            let image = UIGraphicsImageRenderer(size: options.size).image { renderer in
                snapshot.image.draw(at: .zero)
                let path = UIBezierPath()
                for (index, coordinate) in coordinates.enumerated() {
                    let point = snapshot.point(for: coordinate)
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                renderer.cgContext.setStrokeColor(BrandUIColor.primary.cgColor)
                renderer.cgContext.setLineWidth(5)
                renderer.cgContext.setLineJoin(.round)
                renderer.cgContext.setLineCap(.round)
                path.stroke()
            }
            completion(image)
        }
    }

    /// Compatibility wrapper for existing ride-detail previews. ExportPreviewView
    /// uses the points overload so its privacy toggle is applied before capture.
    static func generateSnapshot(for ride: Ride, size: CGSize = CGSize(width: 800, height: 800), completion: @escaping (UIImage?) -> Void) {
        generateSnapshot(points: ride.points ?? [], size: size, completion: completion)
    }
}
