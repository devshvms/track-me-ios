import Foundation
import CoreLocation
#if os(iOS)
import UIKit
#endif

class EmergencyManager {
    static let shared = EmergencyManager()

    private var sosStartTime: Date?

    // NOTE: startBroadcast in v1 iOS does not auto-send an SMS.
    // It is called when the user slides the SOS slider, but HomeView handles presenting
    // the MFMessageComposeViewController. This function just tracks telemetry.
    func startBroadcast() {
        print("SOS Placeholder Triggered - Log action for future backend/SMS integration")
        TelemetryManager.shared.trackSosTriggered(triggerMethod: "in_app_button")
        sosStartTime = Date()
    }

    func resolveBroadcast(falseAlarm: Bool) {
        let duration = Int(Date().timeIntervalSince(sosStartTime ?? Date()))
        TelemetryManager.shared.trackSosResolved(resolutionTimeSeconds: duration, falseAlarm: falseAlarm)
        sosStartTime = nil
    }

    func fetchFreshLocation(timeout: TimeInterval = 2.0, completion: @escaping (CLLocationCoordinate2D?) -> Void) {
        let fetcher = LocationFetcher()
        // Retain fetcher for the duration of the request
        var retainedFetcher: LocationFetcher? = fetcher

        fetcher.fetchLocation(timeout: timeout) { coordinate in
            completion(coordinate)
            retainedFetcher = nil
        }
    }

    func buildEmergencyMessage(template: String, coordinate: CLLocationCoordinate2D?, battery: Float, deviceModel: String, date: Date) -> String {
        var message = template

        let locString: String
        if let coord = coordinate {
            locString = "https://maps.google.com/?q=\(coord.latitude),\(coord.longitude)"
        } else {
            locString = "Location unknown"
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let timeString = formatter.string(from: date)

        let batteryString: String
        if battery >= 0 {
            batteryString = String(format: "%.0f%%", battery * 100)
        } else {
            batteryString = "Unknown"
        }

        message = message.replacingOccurrences(of: "[Location Link]", with: locString)
        message = message.replacingOccurrences(of: "[Battery Percent]", with: batteryString)
        message = message.replacingOccurrences(of: "[Device Name]", with: deviceModel)
        message = message.replacingOccurrences(of: "[Timestamp]", with: timeString)

        return message
    }
}

class LocationFetcher: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var completion: ((CLLocationCoordinate2D?) -> Void)?

    func fetchLocation(timeout: TimeInterval, completion: @escaping (CLLocationCoordinate2D?) -> Void) {
        self.completion = completion
        manager.delegate = self
        manager.requestLocation()

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self = self, self.completion != nil else { return }
            self.manager.stopUpdatingLocation()
            self.manager.delegate = nil
            self.completion?(nil)
            self.completion = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.last {
            completion?(location.coordinate)
            completion = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        completion?(nil)
        completion = nil
    }
}
