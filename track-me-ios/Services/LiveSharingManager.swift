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

    private var isRetryingAuth = false
    private var lastErrorToastAt = Date.distantPast

    // MARK: - Request construction
    private static let requestTimeout: TimeInterval = 15   // parity with Android LiveShareManager (connect/read = 15s)

    /// Builds a POST JSON request for the live-share API with the shared timeout applied.
    static func makeLiveShareRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = requestTimeout
        return request
    }

    private init() {
    }

    private func withAuthToken(forceRefresh: Bool = false, _ completion: @escaping (String?) -> Void) {
        Auth.auth().currentUser?.getIDTokenForcingRefresh(forceRefresh) { token, _ in
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

        var request = Self.makeLiveShareRequest(url: url)

        var body: [String: Any] = [:]
        if let dur = durationMinutes {
            body["durationMinutes"] = dur
        }

        if let username = Auth.auth().currentUser?.displayName {
            body["username"] = username
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        withAuthToken(forceRefresh: true) { [weak self] token in
            guard let self = self else { return }
            var authenticatedRequest = request
            self.applyAuth(&authenticatedRequest, token: token)

            URLSession.shared.dataTask(with: authenticatedRequest) { [weak self] data, response, error in
                guard let self = self else { return }

                let code = (response as? HTTPURLResponse)?.statusCode

                if let error = error {
                    print("Failed to start session: \(error)")
                    DispatchQueue.main.async {
                        self.handleTransportError(error)
                    }
                    return
                }

                guard let data = data, let statusCode = code else {
                    DispatchQueue.main.async {
                        ToastManager.shared.show(message: LocalizationHelper.localized("Invalid response from server"), style: .error)
                    }
                    return
                }

                if statusCode != 200 {
                    if statusCode == 401 || statusCode == 403 {
                        DispatchQueue.main.async {
                            ToastManager.shared.show(message: LiveShareError.message(statusCode: statusCode, error: nil), style: .error)
                        }
                    } else {
                        DispatchQueue.main.async {
                            self.handleHTTPError(statusCode)
                        }
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
            var request = Self.makeLiveShareRequest(url: url)
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
            self.isRetryingAuth = false
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

    private func pushLocation(_ loc: CLLocation, isRetry: Bool = false) {
        guard let sessionId = sessionId, let url = URL(string: APIConfig.LiveShare.locationPush(sessionId: sessionId)) else { return }

        if let expiresAt = expiresAt, Date() > expiresAt {
            stopSession(reason: "Share window elapsed.")
            return
        }

        var request = Self.makeLiveShareRequest(url: url)

        // Fetch battery level
        UIDevice.current.isBatteryMonitoringEnabled = true
        let batteryLevel = Int(UIDevice.current.batteryLevel * 100)

        let body: [String: Any] = [
            "lat": loc.coordinate.latitude,
            "lng": loc.coordinate.longitude,
            "batteryLevel": batteryLevel >= 0 ? batteryLevel : 100, // Handle simulator returning -1
            "speed": max(loc.speed * 3.6, 0), // km/h
            "heading": loc.course >= 0 ? loc.course : 0,
            "timestamp": ISO8601DateFormatter().string(from: loc.timestamp)
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        withAuthToken(forceRefresh: isRetry) { [weak self] token in
            guard let self = self else { return }
            var authenticatedRequest = request
            self.applyAuth(&authenticatedRequest, token: token)

            URLSession.shared.dataTask(with: authenticatedRequest) { [weak self] data, response, error in
                guard let self = self else { return }

                let code = (response as? HTTPURLResponse)?.statusCode

                DispatchQueue.main.async {
                    if let error = error {
                        self.handleTransportError(error)
                        return
                    }

                    switch code {
                    case .some(200...299):
                        self.isRetryingAuth = false
                    case .some(404):
                        ToastManager.shared.show(message: LocalizationHelper.localized("Live sharing expired"), style: .error)
                        self.stopSession(reason: "Session expired on server.")
                    case .some(401):
                        if isRetry {
                            ToastManager.shared.show(message: LiveShareError.message(statusCode: 401, error: nil), style: .error)
                            self.stopSession(reason: "Authentication expired.")
                        } else if !self.isRetryingAuth {
                            self.isRetryingAuth = true
                            self.pushLocation(loc, isRetry: true)
                        }
                    default:
                        self.handleHTTPError(code)
                    }
                }
            }.resume()
        }
    }

    private func handleTransportError(_ error: Error) {
        showThrottledError(message: LiveShareError.message(statusCode: nil, error: error))
    }

    private func handleHTTPError(_ statusCode: Int?) {
        showThrottledError(message: LiveShareError.message(statusCode: statusCode, error: nil))
    }

    private func showThrottledError(message: String) {
        if Date().timeIntervalSince(lastErrorToastAt) > 30 {
            lastErrorToastAt = Date()
            ToastManager.shared.show(message: message, style: .error)
        }
    }
}

enum LiveShareError {
    /// Mirrors Android LiveShareManager.formatGracefulError.
    static func message(statusCode: Int?, error: Error?) -> String {
        if statusCode == 401 || statusCode == 403 {
            return LocalizationHelper.localized("Your sign-in expired. Please sign in again to share your location.")
        }
        if let code = statusCode, [404, 500, 502, 503].contains(code) {
            return LocalizationHelper.localized("Live sharing service is temporarily unavailable. Please try again later.")
        }
        if let urlErr = error as? URLError {
            switch urlErr.code {
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return LocalizationHelper.localized("Unable to reach live share server. Please check your internet connection and try again.")
            case .timedOut, .networkConnectionLost:
                return LocalizationHelper.localized("Connection timed out. Please check your internet connection and try again.")
            case .secureConnectionFailed, .serverCertificateUntrusted:
                return LocalizationHelper.localized("Secure connection to live sharing server failed. Please try again.")
            default: break
            }
        }
        return LocalizationHelper.localized("Unable to connect to live share service. Please check your network connection.")
    }
}
