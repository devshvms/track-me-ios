import Foundation
import CoreLocation
import SwiftUI
import SwiftData
import UserNotifications

enum TrackingState: Int {
    case idle
    case tracking
    case paused
    case gpsLost
    case storageLow   // appended last: keep raw values stable for persistence
}

@Observable
class TrackingManager: NSObject, CLLocationManagerDelegate {
    static let shared = TrackingManager()
    private static let activeRideKey = "activeRideId"

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
    private var storageWarningShown = false
    private var lastStorageCheck = Date.distantPast
    
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

        // Refuse to start if the device can't reliably persist points.
        if StorageHealthMonitor.isLowStorage() {
            ToastManager.shared.show(
                message: LocalizationHelper.localized("Not enough free storage to start tracking. Free up space and try again."),
                style: .error
            )
            return
        }

        let newRide = Ride()
        currentRideId = newRide.id
        UserDefaults.standard.set(newRide.id.uuidString, forKey: Self.activeRideKey)

        // Reset live state for a fresh ride.
        storageWarningShown = false
        lastStorageCheck = Date.distantPast
        state = .tracking
        points.removeAll()
        currentSpeed = 0.0
        totalDistance = 0.0
        durationInMillis = 0
        timeSinceLastGps = 0
        lastGpsTimestamp = Date()

        TelemetryManager.shared.trackRideStarted(rideId: newRide.id.uuidString)

        // Save initially on main thread
        DispatchQueue.main.async {
            DataRepository.shared.saveRide(newRide)
        }

        startLocationUpdatesAndTimer()
        RideActivityManager.shared.startActivity(rideId: newRide.id.uuidString, startedAt: Date())
    }

    /// Shared session bring-up used by both a fresh ride and a restored one.
    private func startLocationUpdatesAndTimer() {
        locationManager.startUpdatingLocation()
        requestTrackingNotification()
        startDurationTimer()
    }

    /// Pushes current stats to the Live Activity. The anchor is recomputed as
    /// `now - elapsed` so the auto-ticking timer excludes paused time. Throttled
    /// unless `force` (used for pause/resume/GPS state transitions).
    private func updateLiveActivity(force: Bool = false) {
        let elapsed = durationInMillis / 1000
        RideActivityManager.shared.update(
            startedAt: Date().addingTimeInterval(-elapsed),
            distanceMeters: totalDistance,
            speedMps: currentSpeed,
            isPaused: state == .paused || state == .storageLow,
            isGpsLost: state == .gpsLost,
            pausedElapsed: elapsed,
            force: force
        )
    }

    /// Parks the ride when the device is critically low on storage: stops
    /// location updates (battery + no useless points), freezes duration (the
    /// timer only accumulates for `.tracking`/`.gpsLost`), and tells the user.
    /// Internal so the repository can route a disk-full write failure here too.
    func enterStorageLowState() {
        guard !(state == .storageLow && storageWarningShown) else { return }
        storageWarningShown = true
        state = .storageLow
        currentSpeed = 0.0
        locationManager.stopUpdatingLocation()

        let content = UNMutableNotificationContent()
        content.title = LocalizationHelper.localized("Storage almost full")
        content.body = LocalizationHelper.localized("Tracking is paused. Free device storage, then resume in TrackMe.")
        content.sound = nil
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "StorageLow", content: content, trigger: nil)
        )

        ToastManager.shared.show(
            message: LocalizationHelper.localized("Storage almost full. Tracking is paused. Free device storage, then resume in TrackMe."),
            style: .error
        )
        updateLiveActivity(force: true)
    }

    private func requestTrackingNotification() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Tracking Ride"
            content.body = "TrackMe is currently recording your route."
            content.sound = nil
            let request = UNNotificationRequest(identifier: "TrackingStarted", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    private func startDurationTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.state == .tracking || self.state == .gpsLost {
                self.durationInMillis += 1000
                if let lastTs = self.lastGpsTimestamp {
                    self.timeSinceLastGps = Date().timeIntervalSince(lastTs)
                    let previous = self.state
                    if self.timeSinceLastGps > 10 {
                        self.state = .gpsLost
                    } else {
                        self.state = .tracking
                    }
                    // Push immediately on a GPS-lost/restored transition, otherwise throttle.
                    self.updateLiveActivity(force: self.state != previous)
                }
            }
        }
    }

    /// Restores an in-progress ride interrupted by an app kill/crash, when it is
    /// still fresh (< 5 min) and Always-authorization is intact. Otherwise clears
    /// the marker and lets `RideRecoveryManager`'s sweep finalize the ride.
    /// This is the iOS-idiomatic substitute for Android's START_STICKY restart.
    func restoreInterruptedSessionIfNeeded(container: ModelContainer) async {
        guard state == .idle, currentRideId == nil else { return }
        guard let idString = UserDefaults.standard.string(forKey: Self.activeRideKey),
              let rideId = UUID(uuidString: idString) else { return }

        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Ride>(predicate: #Predicate { $0.id == rideId })
        guard let ride = try? context.fetch(descriptor).first,
              ride.endTime == nil,
              let stored = ride.points, !stored.isEmpty else {
            UserDefaults.standard.removeObject(forKey: Self.activeRideKey)
            return
        }

        let sorted = stored.sorted { $0.timestamp < $1.timestamp }
        guard let last = sorted.last,
              Date().timeIntervalSince(last.timestamp) < 300,
              locationManager.authorizationStatus == .authorizedAlways else {
            // Stale, or permission downgraded while the app was dead — do not
            // silently resume; the orphan sweep will finalize it.
            UserDefaults.standard.removeObject(forKey: Self.activeRideKey)
            return
        }

        // Rebuild live state and continue the SAME ride so new points append to it.
        currentRideId = rideId
        points = sorted.map {
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude),
                altitude: $0.altitude,
                horizontalAccuracy: $0.accuracy,
                verticalAccuracy: $0.accuracy,
                course: -1,
                speed: $0.speed,
                timestamp: $0.timestamp
            )
        }
        var distance = 0.0
        if points.count > 1 {
            for i in 1..<points.count {
                distance += points[i].distance(from: points[i - 1])
            }
        }
        totalDistance = distance
        durationInMillis = max(0, last.timestamp.timeIntervalSince(ride.startTime)) * 1000
        lastGpsTimestamp = last.timestamp
        timeSinceLastGps = Date().timeIntervalSince(last.timestamp)
        currentSpeed = 0.0
        state = .tracking

        startLocationUpdatesAndTimer()
        RideActivityManager.shared.startActivity(
            rideId: rideId.uuidString,
            startedAt: Date().addingTimeInterval(-durationInMillis / 1000)
        )
        ToastManager.shared.show(message: LocalizationHelper.localized("Resumed your interrupted ride"), style: .info)
    }

    func stopTracking() {
        locationManager.stopUpdatingLocation()
        state = .idle
        timer?.invalidate()
        timer = nil
        storageWarningShown = false
        UserDefaults.standard.removeObject(forKey: Self.activeRideKey)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["StorageLow"])

        RideActivityManager.shared.end(
            startedAt: Date().addingTimeInterval(-durationInMillis / 1000),
            distanceMeters: totalDistance,
            speedMps: 0,
            pausedElapsed: durationInMillis / 1000
        )

        if let id = currentRideId {
            DataRepository.shared.finishRide(rideId: id)
            TelemetryManager.shared.trackRideCompleted(rideId: id.uuidString, durationSeconds: Int(durationInMillis / 1000), distanceKm: totalDistance / 1000.0)

            // A1: shared good-ride hook (parity with Android TrackingService.finalizeRide).
            // Skip junk rides (mirror Android's 10 m / 2 min thresholds). Best-effort +
            // idempotent — must never affect ride saving. The returned transition is what
            // B1 (reveal) / B2 (recap) / B3 (streak) will consume.
            let isJunk = totalDistance < 10.0 && durationInMillis < 2 * 60 * 1000
            if !isJunk {
                let summary = GoodRideSummary(
                    rideId: id.uuidString,
                    finishedAtMillis: Int64(Date().timeIntervalSince1970 * 1000),
                    durationMillis: Int64(durationInMillis),
                    distanceMeters: totalDistance
                )
                // B1: fold in, then surface the bounded reveal — the reveal is the good-ride
                // confirmation, replacing the flat "Ride saved" toast. Persisted one-shot so it
                // survives backgrounding and shows once on Home.
                Task {
                    let transition = await RideStatsStore.shared.recordGoodRide(summary)
                    // B3: emit the streak state event on the first-ride-of-week transition.
                    if transition.isFirstRideOfWeek {
                        TelemetryManager.shared.trackWeeklyStreakUpdated(
                            streakWeeks: transition.streakWeeks, froze: transition.streakFroze)
                    }
                    if let reveal = RevealSelector.select(transition) {
                        await RevealCoordinator.shared.put(reveal)
                    }
                }
            } else {
                // A sub-threshold ride the user chose to save earns no reveal — keep a plain toast.
                ToastManager.shared.show(message: LocalizationHelper.localized("Ride saved successfully"), style: .success)
            }
        }
        currentRideId = nil
        
        // Stop live sharing when the ride ends
        if LiveSharingManager.shared.isActive && LiveSharingManager.shared.isRideLinked {
            LiveSharingManager.shared.stopSession(reason: "Ride ended successfully.")
        }
    }
    
    func pauseTracking() {
        if state == .tracking || state == .gpsLost || state == .storageLow {
            state = .paused
            currentSpeed = 0.0
            updateLiveActivity(force: true)
        }
    }

    func resumeTracking() {
        guard state == .paused || state == .storageLow else { return }

        if state == .storageLow {
            // Re-check before restarting; stay parked if still low.
            if StorageHealthMonitor.isLowStorage() {
                ToastManager.shared.show(
                    message: LocalizationHelper.localized("Storage almost full. Tracking is paused. Free device storage, then resume in TrackMe."),
                    style: .error
                )
                return
            }
            storageWarningShown = false
            // enterStorageLowState() stopped updates — restart them.
            locationManager.startUpdatingLocation()
        }

        state = .tracking
        lastGpsTimestamp = Date()
        timeSinceLastGps = 0
        updateLiveActivity(force: true)
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard state == .tracking || state == .gpsLost, let rideId = currentRideId else { return }

        let recoveredFromGpsLost = state == .gpsLost
        lastGpsTimestamp = Date()
        timeSinceLastGps = 0
        if state == .gpsLost {
            state = .tracking
        }

        // Storage guard (throttled — the resource-values call is a syscall).
        if Date().timeIntervalSince(lastStorageCheck) >= 5 {
            lastStorageCheck = Date()
            if StorageHealthMonitor.isLowStorage() {
                enterStorageLowState()
                return
            }
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

        // 7. Live Activity (throttled; forced when we just regained GPS).
        updateLiveActivity(force: recoveredFromGpsLost)
    }
}
