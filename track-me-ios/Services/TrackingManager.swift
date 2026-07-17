import Foundation
import CoreLocation
import SwiftUI
import UserNotifications

enum TrackingState: Int {
    case idle
    case tracking
    case paused
    case gpsLost
}

@Observable
class TrackingManager: NSObject, CLLocationManagerDelegate {
    static let shared = TrackingManager()
    
    private let locationManager = CLLocationManager()
    
    // State exposed to SwiftUI
    var state: TrackingState = .idle
    var currentRideId: UUID?
    var points: [CLLocation] = [] 
    var currentSpeed: Double = 0.0
    var totalDistance: Double = 0.0
    var durationInMillis: TimeInterval = 0
    var timeSinceLastGps: TimeInterval = 0
    var lastGpsTimestamp: Date?
    var showLocationPermissionExplanation = false
    
    private var timer: Timer?
    private var pendingTrackingStart = false
    
    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 2 // meters
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.showsBackgroundLocationIndicator = true
    }
    
    func startTracking() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            pendingTrackingStart = true
            showLocationPermissionExplanation = true
            return
        case .authorizedWhenInUse:
            pendingTrackingStart = true
            locationManager.requestAlwaysAuthorization()
            return
        case .authorizedAlways:
            beginTracking()
        default:
            ToastManager.shared.show(message: LocalizationHelper.localized("Enable location access in Settings to start tracking."), style: .error)
        }
    }

    func continueAfterLocationExplanation() {
        pendingTrackingStart = true
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()
        case .authorizedAlways:
            beginTracking()
        default:
            ToastManager.shared.show(message: LocalizationHelper.localized("Enable location access in Settings to start tracking."), style: .error)
        }
    }

    func cancelPendingTrackingStart() {
        pendingTrackingStart = false
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard pendingTrackingStart else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        case .authorizedAlways:
            beginTracking()
        case .denied, .restricted:
            pendingTrackingStart = false
            ToastManager.shared.show(message: LocalizationHelper.localized("Location permission is required for offline and background tracking."), style: .error)
        default:
            break
        }
    }

    private func beginTracking() {
        pendingTrackingStart = false
        locationManager.startUpdatingLocation()
        
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted {
                let content = UNMutableNotificationContent()
                content.title = "Tracking Ride"
                content.body = "TrackMe is currently recording your route."
                content.sound = nil
                let request = UNNotificationRequest(identifier: "TrackingStarted", content: content, trigger: nil)
                UNUserNotificationCenter.current().add(request)
            }
        }
        
        state = .tracking
        points.removeAll()
        currentSpeed = 0.0
        totalDistance = 0.0
        durationInMillis = 0
        timeSinceLastGps = 0
        lastGpsTimestamp = Date()
        
        let newRide = Ride()
        currentRideId = newRide.id
        
        let startLat = locationManager.location?.coordinate.latitude ?? 0.0
        let startLon = locationManager.location?.coordinate.longitude ?? 0.0
        TelemetryManager.shared.trackRideStarted(rideId: newRide.id.uuidString, startLatitude: startLat, startLongitude: startLon)
        
        // Save initially on main thread
        DispatchQueue.main.async {
            DataRepository.shared.saveRide(newRide)
        }
        
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.state == .tracking || self.state == .gpsLost {
                self.durationInMillis += 1000
                if let lastTs = self.lastGpsTimestamp {
                    self.timeSinceLastGps = Date().timeIntervalSince(lastTs)
                    if self.timeSinceLastGps > 10 {
                        self.state = .gpsLost
                    } else {
                        self.state = .tracking
                    }
                }
            }
        }
    }
    
    func stopTracking() {
        locationManager.stopUpdatingLocation()
        state = .idle
        timer?.invalidate()
        timer = nil
        
        if let id = currentRideId {
            DataRepository.shared.finishRide(rideId: id)
            TelemetryManager.shared.trackRideCompleted(rideId: id.uuidString, durationSeconds: Int(durationInMillis / 1000), distanceKm: totalDistance / 1000.0)
            ToastManager.shared.show(message: LocalizationHelper.localized("Ride saved successfully"), style: .success)
        }
        currentRideId = nil
        
        // Stop live sharing when the ride ends
        if LiveSharingManager.shared.isActive && LiveSharingManager.shared.isRideLinked {
            LiveSharingManager.shared.stopSession(reason: "Ride ended successfully.")
        }
    }
    
    func pauseTracking() {
        if state == .tracking || state == .gpsLost {
            state = .paused
            currentSpeed = 0.0
        }
    }
    
    func resumeTracking() {
        if state == .paused {
            state = .tracking
            lastGpsTimestamp = Date()
            timeSinceLastGps = 0
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard state == .tracking || state == .gpsLost, let rideId = currentRideId else { return }
        
        lastGpsTimestamp = Date()
        timeSinceLastGps = 0
        if state == .gpsLost {
            state = .tracking
        }
        
        for location in locations {
            // 1. Outlier removal
            if let previous = points.last {
                if GPSProcessor.isOutlier(current: location, previous: previous) {
                    continue
                }
            }
            
            // 2. Smoothing
            let smoothedLocation = GPSProcessor.smooth(points: points, newPoint: location)
            
            // 3. Distance Calculation
            if let previous = points.last {
                let dist = smoothedLocation.distance(from: previous)
                if dist > 0 {
                    totalDistance += dist
                }
            }
            currentSpeed = max(smoothedLocation.speed, 0)
            points.append(smoothedLocation)
            
            // 4. Auto-Pause
            let fifteenSecAgo = smoothedLocation.timestamp.addingTimeInterval(-15)
            let recentWindow = points.filter { $0.timestamp >= fifteenSecAgo }
            let isPaused = GPSProcessor.calculateAutoPause(recentPoints: recentWindow)
            
            // 5. Offline-First Database Write
            DataRepository.shared.savePointBackground(
                rideId: rideId,
                lat: smoothedLocation.coordinate.latitude,
                lng: smoothedLocation.coordinate.longitude,
                alt: smoothedLocation.altitude,
                acc: smoothedLocation.horizontalAccuracy,
                spd: currentSpeed,
                ts: smoothedLocation.timestamp,
                paused: isPaused
            )
            
            // 6. Push to Live Sharing Manager
            if LiveSharingManager.shared.isActive {
                LiveSharingManager.shared.updateLatestLocation(smoothedLocation)
            }
        }
    }
}
