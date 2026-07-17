import Foundation
import CoreLocation

class GPXExporter {
    static func generateGPX(from ride: Ride) -> URL? {
        var gpx = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        gpx += "<gpx version=\"1.1\" creator=\"TrackMe iOS\">\n"
        gpx += "  <trk>\n"
        gpx += "    <name>\(ride.title ?? "TrackMe Ride")</name>\n"
        gpx += "    <trkseg>\n"
        
        let formatter = ISO8601DateFormatter()
        
        let sortedPoints = (ride.points ?? []).sorted { $0.timestamp < $1.timestamp }
        for point in sortedPoints {
            gpx += "      <trkpt lat=\"\(point.latitude)\" lon=\"\(point.longitude)\">\n"
            gpx += "        <ele>\(point.altitude)</ele>\n"
            gpx += "        <time>\(formatter.string(from: point.timestamp))</time>\n"
            gpx += "      </trkpt>\n"
        }
        
        gpx += "    </trkseg>\n"
        gpx += "  </trk>\n"
        gpx += "</gpx>"
        
        let safeTitle = (ride.title ?? "TrackMe_Ride").replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "/", with: "-")
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let tempURL = cacheDir.appendingPathComponent("\(safeTitle).gpx")
        do {
            try gpx.write(to: tempURL, atomically: true, encoding: .utf8)
            return tempURL
        } catch {
            return nil
        }
    }
}
