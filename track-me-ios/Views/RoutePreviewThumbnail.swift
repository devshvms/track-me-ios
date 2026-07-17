import SwiftUI
import CoreLocation

struct RoutePreviewThumbnail: View {
    let points: [GPSPoint]
    
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
                }
            } else {
                Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                    .foregroundColor(.blue.opacity(0.6))
                    .font(.system(size: 20))
            }
        }
        .frame(width: 80, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
