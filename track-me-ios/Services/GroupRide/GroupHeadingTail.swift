import CoreLocation

/// A short, session-only position history for one other rider. It is kept out
/// of GroupSessionState and GroupSessionStore so §5.1.4's no-history promise
/// remains true outside the live screen (scope 1.7.3 §3).
struct GroupHeadingPoint: Equatable {
    let uid: String
    let latitude: Double
    let longitude: Double
    let serverTsMillis: Int64
    let receivedAtElapsedMillis: Int64

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct GroupHeadingTailSegment: Identifiable {
    let uid: String
    let start: CLLocationCoordinate2D
    let end: CLLocationCoordinate2D
    let opacity: Double
    let lineWidth: Double

    var id: String {
        "\(uid):\(start.latitude):\(start.longitude):\(end.latitude):\(end.longitude)"
    }
}
