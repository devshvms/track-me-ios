import Foundation
import CoreLocation
#if os(iOS)
import UIKit
#endif

class EmergencyManager {
    static let shared = EmergencyManager()

    /// Parity with Android `EmergencyManager.EMERGENCY_TRIGGERED_FOR_RIDE_KEY`. Persisted so the
    /// suppression survives process death between SOS and ride finalization.
    private static let emergencyTriggeredForRideKey = "emergency_triggered_for_ride"

    private let defaults: UserDefaults
    /// Guards the suppression bit: it is written from the SOS surface (main actor) and read during
    /// ride finalization, which may run off the main actor. Mirrors Android's `@Synchronized`.
    private let lock = NSLock()

    private var sosStartTime: Date?

    /// Whether the current ride has entered the emergency flow. Deliberately separate from whether
    /// SOS is *currently* active: the user can resolve SOS before stopping the ride, but the
    /// celebratory post-ride surfaces must remain suppressed for that ride.
    private var emergencyTriggeredForRide: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.emergencyTriggeredForRide = defaults.bool(forKey: Self.emergencyTriggeredForRideKey)
    }

    // NOTE: startBroadcast in v1 iOS does not auto-send an SMS.
    // It is called when the user slides the SOS slider, but HomeView handles presenting
    // the MFMessageComposeViewController. This function just tracks telemetry.
    func startBroadcast() {
        print("SOS Placeholder Triggered - Log action for future backend/SMS integration")
        TelemetryManager.shared.trackSosTriggered(triggerMethod: "in_app_button")
        sosStartTime = Date()
        lock.lock()
        defer { lock.unlock() }
        emergencyTriggeredForRide = true
        persistSuppression()
    }

    func resolveBroadcast(falseAlarm: Bool) {
        let duration = Int(Date().timeIntervalSince(sosStartTime ?? Date()))
        TelemetryManager.shared.trackSosResolved(resolutionTimeSeconds: duration, falseAlarm: falseAlarm)
        sosStartTime = nil
        // Deliberately does NOT clear `emergencyTriggeredForRide`: the ride still had an emergency,
        // so it must not earn a celebration. Parity with Android `stopEmergency()`.
    }

    /// Whether an emergency is currently in flight (iOS analogue of Android's
    /// `isEmergencyActive`; iOS has no repeating broadcast loop, so the SOS clock is the state).
    var isEmergencyActive: Bool { sosStartTime != nil }

    /// Start a fresh per-ride suppression window. Called when a new ride begins — including the
    /// second half of an auto-split — but NOT when an interrupted ride is restored, so a restored
    /// ride keeps the bit persisted before the kill. Parity with Android `beginRideSession()`.
    func beginRideSession() {
        lock.lock()
        defer { lock.unlock() }
        // Carry an already-active SOS across a ride split; otherwise the new segment could
        // incorrectly earn a celebratory reveal while the emergency flow is still running.
        emergencyTriggeredForRide = isEmergencyActive
        persistSuppression()
    }

    /// Consume the per-ride suppression bit exactly once at finalization.
    /// Parity with Android `consumeRideSuppression()`.
    @discardableResult
    func consumeRideSuppression() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasTriggered = defaults.bool(forKey: Self.emergencyTriggeredForRideKey)
        emergencyTriggeredForRide = false
        defaults.removeObject(forKey: Self.emergencyTriggeredForRideKey)
        return wasTriggered
    }

    private func persistSuppression() {
        defaults.set(emergencyTriggeredForRide, forKey: Self.emergencyTriggeredForRideKey)
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
