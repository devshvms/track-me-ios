import Foundation
import SwiftUI
import CoreLocation
import Combine
import FirebaseAuth

@Observable
class LiveSharingManager {
    static let shared = LiveSharingManager()
    
    var isActive: Bool = false
    var isRideLinked: Bool = false
    var sessionId: String?
    var shareLink: String?
    var expiresAt: Date?
    var sessionStartTime: Date?
    
    // Remaining time in seconds (updated for UI)
    var remainingSeconds: Int = 0
    
    private var pushTimer: Timer?
    private var countdownTimer: Timer?
    
    // We will keep a reference to the latest location to push
    var latestLocation: CLLocation?
    
    private init() {
    }

    private func withAuthToken(_ completion: @escaping (String?) -> Void) {
        Auth.auth().currentUser?.getIDToken { token, _ in
            completion(token)
        }
    }

    private func applyAuth(_ request: inout URLRequest, token: String?) {
        if let token = token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }
    
    // Helper to get AppStorage values directly
    private var updateFrequency: TimeInterval {
        let val = UserDefaults.standard.integer(forKey: "liveShareFrequency")
        return val == 0 ? 10 : TimeInterval(val)
    }
    
    func startSession(durationMinutes: Int?) {
        guard let url = URL(string: APIConfig.LiveShare.startSession) else { return }
        
        self.isRideLinked = (durationMinutes == nil)
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var body: [String: Any] = [:]
        if let dur = durationMinutes {
            body["durationMinutes"] = dur
        }
        
        if let username = Auth.auth().currentUser?.displayName {
            body["username"] = username
        }
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        withAuthToken { [weak self] token in
            guard let self = self else { return }
            var authenticatedRequest = request
            self.applyAuth(&authenticatedRequest, token: token)
            
            URLSession.shared.dataTask(with: authenticatedRequest) { [weak self] data, response, error in
                guard let self = self else { return }
                
                if let error = error {
                    print("Failed to start session: \(error)")
                    DispatchQueue.main.async {
                        ToastManager.shared.show(message: LocalizationHelper.localized("Failed to start live share"), style: .error)
                    }
                    return
                }
                
                guard let data = data else {
                    DispatchQueue.main.async {
                        ToastManager.shared.show(message: LocalizationHelper.localized("Invalid response from server"), style: .error)
                    }
                    return
                }
                
                do {
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let sessionId = json["sessionId"] as? String,
                       let shareLink = json["shareLink"] as? String {
                        
                        let expiresAtStr = json["expiresAt"] as? String
                        
                        let formatter = ISO8601DateFormatter()
                        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                        
                        var newExpiresAt: Date? = nil
                        if let expiresStr = expiresAtStr {
                            newExpiresAt = formatter.date(from: expiresStr)
                        }
                        if newExpiresAt == nil {
                            newExpiresAt = Date().addingTimeInterval(TimeInterval((durationMinutes ?? 1440) * 60))
                        }
                        
                        DispatchQueue.main.async {
                            self.sessionId = sessionId
                            self.shareLink = shareLink
                            self.expiresAt = newExpiresAt
                            self.sessionStartTime = Date()
                            self.isActive = true
                            
                            TelemetryManager.shared.trackLiveShareStarted(shareId: sessionId, recipientCount: 0)
                            
                            ToastManager.shared.show(message: LocalizationHelper.localized("Live sharing started"), style: .success)
                            
                            if let loc = self.latestLocation {
                                self.pushLocation(loc)
                            } else if let loc = TrackingManager.shared.points.last {
                                self.pushLocation(loc)
                            }
                            
                            self.startTimers()
                        }
                    } else {
                        DispatchQueue.main.async {
                            ToastManager.shared.show(message: LocalizationHelper.localized("Failed to parse sharing session"), style: .error)
                        }
                    }
                } catch {
                    print("Failed to parse start session response: \(error)")
                    DispatchQueue.main.async {
                        ToastManager.shared.show(message: LocalizationHelper.localized("Failed to parse sharing session"), style: .error)
                    }
                }
            }.resume()
        }
    }
    
    func stopSession(reason: String = "Share session ended manually.") {
        if let sessionId = sessionId, let url = URL(string: APIConfig.LiveShare.stopSession(sessionId: sessionId)) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = ["stopReason": reason]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            withAuthToken { [request] token in
                var authenticatedRequest = request
                self.applyAuth(&authenticatedRequest, token: token)
                URLSession.shared.dataTask(with: authenticatedRequest).resume()
            }
        }
        
        DispatchQueue.main.async {
            if let id = self.sessionId, let startTime = self.sessionStartTime {
                let duration = Int(Date().timeIntervalSince(startTime))
                TelemetryManager.shared.trackLiveShareEnded(shareId: id, durationSeconds: duration)
            }
            self.isActive = false
            self.sessionId = nil
            self.shareLink = nil
            self.expiresAt = nil
            self.sessionStartTime = nil
            self.stopTimers()
        }
    }
    
    private func startTimers() {
        stopTimers()
        
        // Push Timer
        pushTimer = Timer.scheduledTimer(withTimeInterval: updateFrequency, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Only push if the ride is actually actively tracking (as per user request)
            if TrackingManager.shared.state == .tracking, let loc = self.latestLocation {
                self.pushLocation(loc)
            }
        }
        
        // UI Countdown Timer
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let expiresAt = self.expiresAt else { return }
            let remaining = Int(expiresAt.timeIntervalSinceNow)
            
            DispatchQueue.main.async {
                if remaining <= 0 {
                    let durStr = self.isRideLinked ? "24 hours" : "the configured duration"
                    self.stopSession(reason: "Max share duration reached (\(durStr)).")
                } else {
                    self.remainingSeconds = remaining
                }
            }
        }
    }
    
    private func stopTimers() {
        pushTimer?.invalidate()
        pushTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
    }
    
    func updateLatestLocation(_ location: CLLocation) {
        self.latestLocation = location
    }
    
    private func pushLocation(_ loc: CLLocation) {
        guard let sessionId = sessionId, let url = URL(string: APIConfig.LiveShare.locationPush(sessionId: sessionId)) else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Fetch battery level
        UIDevice.current.isBatteryMonitoringEnabled = true
        let batteryLevel = Int(UIDevice.current.batteryLevel * 100)
        
        let body: [String: Any] = [
            "lat": loc.coordinate.latitude,
            "lon": loc.coordinate.longitude,
            "batteryLevel": batteryLevel >= 0 ? batteryLevel : 100, // Handle simulator returning -1
            "speed": max(loc.speed * 3.6, 0), // km/h
            "heading": loc.course >= 0 ? loc.course : 0,
            "timestamp": ISO8601DateFormatter().string(from: loc.timestamp)
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        withAuthToken { [weak self] token in
            guard let self = self else { return }
            var authenticatedRequest = request
            self.applyAuth(&authenticatedRequest, token: token)
            
            URLSession.shared.dataTask(with: authenticatedRequest) { [weak self] data, response, error in
                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 404 {
                        DispatchQueue.main.async {
                            ToastManager.shared.show(message: LocalizationHelper.localized("Live sharing expired"), style: .error)
                            self?.stopSession(reason: "Session expired on server.")
                        }
                    }
                }
            }.resume()
        }
    }
}
