import Foundation
import CoreLocation

class EmergencyManager {
    static let shared = EmergencyManager()
    
    private var sosStartTime: Date?
    
    func startBroadcast() {
        print("SOS Placeholder Triggered - Log action for future backend/SMS integration")
        let lat = TrackingManager.shared.points.last?.coordinate.latitude ?? 0.0
        let lon = TrackingManager.shared.points.last?.coordinate.longitude ?? 0.0
        TelemetryManager.shared.trackSosTriggered(latitude: lat, longitude: lon, triggerMethod: "in_app_button")
        sosStartTime = Date()
    }
    
    func resolveBroadcast(falseAlarm: Bool) {
        let duration = Int(Date().timeIntervalSince(sosStartTime ?? Date()))
        TelemetryManager.shared.trackSosResolved(resolutionTimeSeconds: duration, falseAlarm: falseAlarm)
        sosStartTime = nil
    }
}
