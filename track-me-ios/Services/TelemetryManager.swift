import Foundation
import SwiftUI
import PostHog

class TelemetryManager {
    static let shared = TelemetryManager()
    
    @AppStorage("enableTelemetry") private var isTelemetryEnabled: Bool = false
    
    private init() {}
    
    // MARK: - PostHog Setup
    func initializePostHog() {
        let configuration = PostHogConfig(apiKey: "phc_ohRdDdd3VeXqFJPWefGv8vF3ogo4cUHaw9hrMLvDmP8k", host: "https://eu.posthog.com")
        // PostHog handles standard properties automatically (OS Version, Screen Dimensions, etc)
        // Opt out automatically if telemetry is disabled
        configuration.optOut = !isTelemetryEnabled
        PostHogSDK.shared.setup(configuration)
    }
    
    // Call this if the user toggles the feature flag in Settings
    func updateOptOutStatus() {
        if isTelemetryEnabled {
            PostHogSDK.shared.optIn()
        } else {
            PostHogSDK.shared.optOut()
        }
    }
    
    private func shouldTrack() -> Bool {
        return isTelemetryEnabled
    }
    
    // MARK: - 1. Installs & Active Devices
    // Handled automatically by PostHog
    
    // MARK: - 2. Time Spent (App and Screens)
    func trackScreenViewed(screenName: String, durationSeconds: Int) {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("screen_viewed", properties: [
            "screen_name": screenName,
            "duration_seconds": durationSeconds
        ])
    }
    
    // MARK: - 3. Rides Tracking
    func trackRideStarted(rideId: String, startLatitude: Double, startLongitude: Double) {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("ride_started", properties: [
            "ride_id": rideId,
            "start_latitude": startLatitude,
            "start_longitude": startLongitude
        ])
    }
    
    func trackRideCompleted(rideId: String, durationSeconds: Int, distanceKm: Double) {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("ride_completed", properties: [
            "ride_id": rideId,
            "duration_seconds": durationSeconds,
            "distance_km": distanceKm
        ])
    }
    
    // MARK: - 4. Live Sharing
    func trackLiveShareStarted(shareId: String, recipientCount: Int) {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("live_share_started", properties: [
            "share_id": shareId,
            "recipient_count": recipientCount
        ])
    }
    
    func trackLiveShareEnded(shareId: String, durationSeconds: Int) {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("live_share_ended", properties: [
            "share_id": shareId,
            "duration_seconds": durationSeconds
        ])
    }
    
    // MARK: - 5. SOS Usage
    func trackSosTriggered(latitude: Double, longitude: Double, triggerMethod: String) {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("sos_triggered", properties: [
            "latitude": latitude,
            "longitude": longitude,
            "trigger_method": triggerMethod
        ])
    }
    
    func trackSosResolved(resolutionTimeSeconds: Int, falseAlarm: Bool) {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("sos_resolved", properties: [
            "resolution_time_seconds": resolutionTimeSeconds,
            "false_alarm": falseAlarm
        ])
    }
    
    // MARK: - 6. User Authentication
    func identifyUser(userId: String) {
        guard shouldTrack() else { return }
        PostHogSDK.shared.identify(userId)
    }
    
    func trackUserLoggedIn() {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("user_logged_in")
    }
    
    func trackUserSignedUp() {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("user_signed_up")
    }
    
    // MARK: - 7. App Performance & Errors
    func trackAppCrashDetected(errorMessage: String, errorStack: String) {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("app_crash_detected", properties: [
            "error_message": errorMessage,
            "error_stack": errorStack
        ])
    }
    
    func trackScreenStuckDetected(screenName: String, stuckDurationSeconds: Int) {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("screen_stuck_detected", properties: [
            "screen_name": screenName,
            "stuck_duration_seconds": stuckDurationSeconds
        ])
    }
    
    // MARK: - 8. Account & Data Management
    func trackAccountDeletionRequested(reason: String?) {
        guard shouldTrack() else { return }
        var props: [String: Any] = [:]
        if let reason = reason, !reason.isEmpty {
            props["reason"] = reason
        }
        PostHogSDK.shared.capture("account_deletion_requested", properties: props.isEmpty ? nil : props)
    }
    
    func trackDataDownloadRequested() {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("data_download_requested")
    }
}
