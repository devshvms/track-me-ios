import Foundation
import MapKit
import UIKit

class ImageExporter {
    static func generateSnapshot(for ride: Ride, size: CGSize = CGSize(width: 800, height: 800), completion: @escaping (UIImage?) -> Void) {
        let sortedPoints = (ride.points ?? []).sorted { $0.timestamp < $1.timestamp }
        guard !sortedPoints.isEmpty else {
            completion(nil)
            return
        }
        
        let coordinates = sortedPoints.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        
        var minLat = coordinates[0].latitude
        var maxLat = coordinates[0].latitude
        var minLon = coordinates[0].longitude
        var maxLon = coordinates[0].longitude
        
        for coord in coordinates {
            minLat = min(minLat, coord.latitude)
            maxLat = max(maxLat, coord.latitude)
            minLon = min(minLon, coord.longitude)
            maxLon = max(maxLon, coord.longitude)
        }
        
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: (maxLat - minLat) * 1.5, longitudeDelta: (maxLon - minLon) * 1.5)
        
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: center, span: span)
        options.size = size
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            options.scale = windowScene.screen.scale
        } else {
            options.scale = 2.0
        }
        
        let snapshotter = MKMapSnapshotter(options: options)
        snapshotter.start { snapshot, error in
            guard let snapshot = snapshot, error == nil else {
                completion(nil)
                return
            }
            
            let image = UIGraphicsImageRenderer(size: options.size).image { context in
                snapshot.image.draw(at: .zero)
                
                let path = UIBezierPath()
                for (index, coordinate) in coordinates.enumerated() {
                    let point = snapshot.point(for: coordinate)
                    if index == 0 {
                        path.move(to: point)
                    } else {
                        path.addLine(to: point)
                    }
                }
                
                context.cgContext.setStrokeColor(BrandUIColor.primary.cgColor)
                context.cgContext.setLineWidth(5)
                context.cgContext.setLineJoin(.round)
                context.cgContext.setLineCap(.round)
                path.stroke()
            }
            
            completion(image)
        }
    }
}
