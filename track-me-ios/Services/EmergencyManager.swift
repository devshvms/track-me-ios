import Foundation
import CoreLocation

class EmergencyManager {
    static let shared = EmergencyManager()
    
    private var sosStartTime: Date?
    
    func startBroadcast() {
        print("SOS Placeholder Triggered - Log action for future backend/SMS integration")
        // No precise coordinates in telemetry (A1 / TASK-016 no-PII rule).
        TelemetryManager.shared.trackSosTriggered(triggerMethod: "in_app_button")
        sosStartTime = Date()
    }
    
    func resolveBroadcast(falseAlarm: Bool) {
        let duration = Int(Date().timeIntervalSince(sosStartTime ?? Date()))
        TelemetryManager.shared.trackSosResolved(resolutionTimeSeconds: duration, falseAlarm: falseAlarm)
        sosStartTime = nil
    }
}
