import Foundation
import UIKit

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

    static func appleDirectionsURL(lat: Double, lng: Double) -> URL? {
        URL(string: "http://maps.apple.com/?daddr=\(coordinates(lat: lat, lng: lng))&dirflg=d")
    }

    static func googleDirectionsURL(lat: Double, lng: Double) -> URL? {
        URL(string: "comgooglemaps://?daddr=\(coordinates(lat: lat, lng: lng))&directionsmode=driving")
    }

    private static func coordinates(lat: Double, lng: Double) -> String {
        String(
            format: "%.6f,%.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            lat,
            lng
        )
    }
}

enum GroupDirectionsProvider {
    case apple
    case google

    var isAvailable: Bool {
        switch self {
        case .apple: true
        case .google:
            URL(string: "comgooglemaps://").map(UIApplication.shared.canOpenURL) ?? false
        }
    }

    func url(lat: Double, lng: Double) -> URL? {
        switch self {
        case .apple: GroupDestinationLinks.appleDirectionsURL(lat: lat, lng: lng)
        case .google: GroupDestinationLinks.googleDirectionsURL(lat: lat, lng: lng)
        }
    }
}
