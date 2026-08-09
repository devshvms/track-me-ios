import Foundation

enum GroupDestinationLinks {
    static func appleMapsURL(lat: Double, lng: Double) -> URL? {
        let coordinates = String(
            format: "%.6f,%.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            lat,
            lng
        )
        return URL(string: "http://maps.apple.com/?ll=\(coordinates)")
    }

    static func calendarLocation(lat: Double?, lng: Double?) -> String? {
        guard let lat, let lng, let url = appleMapsURL(lat: lat, lng: lng) else { return nil }
        return url.absoluteString
    }
}
