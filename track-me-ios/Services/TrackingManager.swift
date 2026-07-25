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
    private let motionSensor = MotionSensorManager()

    // State exposed to SwiftUI
    var state: TrackingState = .idle
    var currentRideId: UUID?
    var points: [CLLocation] = []
    var currentSpeed: Double = 0.0
    var totalDistance: Double = 0.0
    var durationInMillis: TimeInterval = 0
    var isAutoPaused: Bool = false
    var timeSinceLastGps: TimeInterval = 0
    var lastGpsTimestamp: Date?
    var showLocationPermissionExplanation = false
    var showLocationDeniedRecovery = false
    
    private static let askedAlwaysKey = "hasRequestedAlwaysUpgrade"
    private var hasAskedAlways: Bool {
        get { UserDefaults.standard.bool(forKey: Self.askedAlwaysKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.askedAlwaysKey) }
    }

    private var mappedAuth: LocationAuth {
        switch locationManager.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .authorizedWhenInUse: return .whenInUse
        case .authorizedAlways: return .always
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .notDetermined
        }
    }

    private var timer: Timer?
    private var pendingTrackingStart = false
    private var storageWarningShown = false
    private var splitWarningShown = false
    private var lastStorageCheck = Date.distantPast

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 2 // meters
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.showsBackgroundLocationIndicator = true
        // TrackMe records a continuous ride; do NOT let Core Location pause the
        // stream on its own judgement — it often fails to auto-resume, silently
        // truncating a ride in the background. We stop updates explicitly in
        // stopTracking()/enterStorageLowState(). activityType tunes the location
        // engine for human-powered movement (parity with Android's continuous FGS).
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.activityType = .fitness
    }

    private func requestAlwaysUpgradeIfAppropriate() {
        guard LocationStartDecision.shouldRequestAlwaysUpgrade(
                status: mappedAuth, hasAskedAlways: hasAskedAlways) else { return }
        hasAskedAlways = true
        locationManager.requestAlwaysAuthorization()
    }

    private func offerDeniedRecovery() {
        showLocationDeniedRecovery = true
    }

    func startTracking() {
        switch LocationStartDecision.action(for: mappedAuth, afterPrimer: false) {
        case .showPrimer:
            pendingTrackingStart = true
            showLocationPermissionExplanation = true
        case .requestWhenInUse:
            pendingTrackingStart = true
            locationManager.requestWhenInUseAuthorization()
        case .begin:
            beginTracking()
            requestAlwaysUpgradeIfAppropriate()
        case .deniedRecovery:
            pendingTrackingStart = false
            offerDeniedRecovery()
        }
    }

    func continueAfterLocationExplanation() {
        pendingTrackingStart = true
        switch LocationStartDecision.action(for: mappedAuth, afterPrimer: true) {
        case .requestWhenInUse:
            locationManager.requestWhenInUseAuthorization()
        case .begin:
            beginTracking()
            requestAlwaysUpgradeIfAppropriate()
        case .deniedRecovery:
            pendingTrackingStart = false
            offerDeniedRecovery()
        case .showPrimer:
            break
        }
    }

    func cancelPendingTrackingStart() {
        pendingTrackingStart = false
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard pendingTrackingStart else { return }
        switch mappedAuth {
        case .whenInUse, .always:
            beginTracking()
            requestAlwaysUpgradeIfAppropriate()
        case .denied, .restricted:
            pendingTrackingStart = false
            offerDeniedRecovery()
        case .notDetermined:
            break
        }
    }

    static func shouldRearmOnInvoluntaryPause(state: TrackingState) -> Bool {
        state == .tracking || state == .gpsLost
    }

    /// Core Location paused updates despite pausesLocationUpdatesAutomatically = false
    /// (defensive: should be rare). If we're mid-ride, immediately re-arm the stream
    /// so the ride doesn't silently flat-line. Do NOT change TrackingState here — this
    /// is an involuntary system pause, not a user pause; the ride is still "tracking".
    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        guard Self.shouldRearmOnInvoluntaryPause(state: state) else { return }
        TelemetryManager.shared.trackLocationUpdatesPaused()
        manager.startUpdatingLocation()
    }

    func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        // Nothing required — didUpdateLocations resumes naturally. Log for telemetry.
        TelemetryManager.shared.trackLocationUpdatesResumed()
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
        splitWarningShown = false
        lastStorageCheck = Date.distantPast
        state = .tracking
        points.removeAll(keepingCapacity: false)
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
        if MotionSensorManager.isMotionFusionEnabled {
            motionSensor.startListening()
        }
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
            isPaused: state == .paused || state == .storageLow || isAutoPaused,
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
                let previousAutoPaused = self.isAutoPaused
                if self.state == .tracking {
                    let start = Date().addingTimeInterval(-GPSProcessor.autoPauseWindow)
                    self.isAutoPaused = AutoPausePreference.isEnabled() && GPSProcessor.calculateAutoPause(recentPoints: self.points.filter { $0.timestamp >= start })
                } else { self.isAutoPaused = false }
                if !self.isAutoPaused { self.durationInMillis += 1000 }
                if let lastTs = self.lastGpsTimestamp {
                    self.timeSinceLastGps = Date().timeIntervalSince(lastTs)
                    let previous = self.state
                    if self.timeSinceLastGps > 10 {
                        self.state = .gpsLost
                    } else {
                        self.state = .tracking
                    }
                    // Push immediately on a GPS-lost/restored transition, otherwise throttle.
                    self.updateLiveActivity(force: self.state != previous || previousAutoPaused != self.isAutoPaused)
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
              locationManager.authorizationStatus == .authorizedAlways || locationManager.authorizationStatus == .authorizedWhenInUse else {
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
        if sorted.count > 1 {
            for i in 1..<sorted.count {
                let p1 = sorted[i - 1]
                let p2 = sorted[i]

                let dist = CLLocation(latitude: p1.latitude, longitude: p1.longitude)
                    .distance(from: CLLocation(latitude: p2.latitude, longitude: p2.longitude))

                if MotionSensorManager.distanceShouldAccumulate(state: .tracking, isPaused: p2.isPaused, dist: dist, effectiveSpeed: p2.speed) {
                    distance += dist
                }
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
        motionSensor.stopListening()
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
            let endedAt = points.last?.timestamp ?? Date()
            finalizeSegment(id: id, endedAt: endedAt)
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
        if MotionSensorManager.isMotionFusionEnabled {
            motionSensor.startListening()
        }
        lastGpsTimestamp = Date()
        timeSinceLastGps = 0
        updateLiveActivity(force: true)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard state == .tracking || state == .gpsLost, let rideId = currentRideId else { return }

        let accumulationState = state
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

            // 3. Distance Calculation & Auto-Pause Gate
            let rawSpeed = max(smoothedLocation.speed, 0)
            let dist = points.last.map { smoothedLocation.distance(from: $0) } ?? 0

            let isHardwareStill = MotionSensorManager.isMotionFusionEnabled && motionSensor.isDeviceStationary()
            let isStationaryDrift = MotionSensorManager.isMotionFusionEnabled && !points.isEmpty && rawSpeed < MotionSensorManager.driftSpeedThreshold && dist < MotionSensorManager.driftDistanceThreshold
            let effectiveSpeed = (isHardwareStill || isStationaryDrift) ? 0 : rawSpeed

            let isPaused: Bool
            if isHardwareStill || isStationaryDrift {
                isPaused = true
            } else if AutoPausePreference.isEnabled() {
                let fifteenSecAgo = smoothedLocation.timestamp.addingTimeInterval(-15)
                let recentWindow = points.filter { $0.timestamp >= fifteenSecAgo }
                isPaused = GPSProcessor.calculateAutoPause(recentPoints: recentWindow)
            } else { isPaused = false }

            currentSpeed = effectiveSpeed
            if MotionSensorManager.distanceShouldAccumulate(state: accumulationState, isPaused: isPaused, dist: dist, effectiveSpeed: effectiveSpeed) {
                totalDistance += dist
            }

            points.append(smoothedLocation)


            // 5. Offline-First Database Write
            DataRepository.shared.savePointBackground(
                rideId: rideId,
                lat: smoothedLocation.coordinate.latitude,
                lng: smoothedLocation.coordinate.longitude,
                alt: smoothedLocation.altitude,
                acc: smoothedLocation.horizontalAccuracy,
                spd: effectiveSpeed,
                ts: smoothedLocation.timestamp,
                paused: isPaused
            )

            // 6. Push to Live Sharing Manager
            if LiveSharingManager.shared.isActive {
                LiveSharingManager.shared.updateLatestLocation(smoothedLocation)
            }

            // 7. Auto-Split Evaluation
            switch RideSplitPolicy.evaluate(pointCount: points.count, alreadyWarned: splitWarningShown) {
            case .warn:
                splitWarningShown = true
                showLongRideWarningNotification()
            case .split:
                splitCurrentRide()
                return // stop processing this batch; Part 2 handles the next fix
            case .none:
                break
            }
        }

        // 7. Live Activity (throttled; forced when we just regained GPS).
        updateLiveActivity(force: recoveredFromGpsLost)
    }

    // MARK: - Auto-Split & Finalization Helpers

    /// Finalize the ride identified by `id` using the authoritative in-memory
    /// segment distance/duration. Shared by normal stop and auto-split so the
    /// A1 good-ride hook + telemetry fire identically on both paths.
    private func finalizeSegment(id: UUID, endedAt: Date) {
        DataRepository.shared.finishRide(rideId: id)
        TelemetryManager.shared.trackRideCompleted(
            rideId: id.uuidString,
            durationSeconds: Int(durationInMillis / 1000),
            distanceKm: totalDistance / 1000.0)

        let isJunk = totalDistance < 10.0 && durationInMillis < 2 * 60 * 1000
        if !isJunk {
            let summary = GoodRideSummary(
                rideId: id.uuidString,
                finishedAtMillis: Int64(endedAt.timeIntervalSince1970 * 1000),
                durationMillis: Int64(durationInMillis),
                distanceMeters: totalDistance
            )
            Task {
                let transition = await RideStatsStore.shared.recordGoodRide(summary)
                if transition.isFirstRideOfWeek {
                    TelemetryManager.shared.trackWeeklyStreakUpdated(
                        streakWeeks: transition.streakWeeks, froze: transition.streakFroze)
                }
                if let reveal = RevealSelector.select(transition) {
                    await RevealCoordinator.shared.put(reveal)
                }
            }
        } else {
            ToastManager.shared.show(message: LocalizationHelper.localized("Ride saved successfully"), style: .success)
        }
    }

    private func splitCurrentRide() {
        guard let oldId = currentRideId else { return }
        let endedAt = points.last?.timestamp ?? Date()

        // 1. Finalize Part 1 (telemetry + A1 hook + cloud sync via finishRide's unsynced flag).
        finalizeSegment(id: oldId, endedAt: endedAt)

        // 2. Start Part 2 in the SAME session — do NOT stop location/timer/Live Activity.
        let part2 = Ride(title: (LocalizationHelper.localized("Ride")) + " (" + LocalizationHelper.localized("Part 2") + ")")
        currentRideId = part2.id
        UserDefaults.standard.set(part2.id.uuidString, forKey: Self.activeRideKey)
        DispatchQueue.main.async { DataRepository.shared.saveRide(part2) }
        TelemetryManager.shared.trackRideStarted(rideId: part2.id.uuidString)

        // 3. Reset per-segment live state (THIS is the memory + O(n²) fix).
        points.removeAll(keepingCapacity: false)
        totalDistance = 0.0
        durationInMillis = 0
        splitWarningShown = false

        // 4. Roll the Live Activity over to the new ride (keep it visible — no gap).
        RideActivityManager.shared.end(
            startedAt: endedAt.addingTimeInterval(-durationInMillis / 1000),
            distanceMeters: 0,
            speedMps: 0,
            pausedElapsed: 0
        )
        RideActivityManager.shared.startActivity(rideId: part2.id.uuidString, startedAt: Date())

        // 5. Keep live sharing linked to the ongoing session (do NOT stop it).
        showAutoSplitNotification()
    }

    private func showLongRideWarningNotification() {
        let content = UNMutableNotificationContent()
        content.title = LocalizationHelper.localized("Long Ride")
        content.body = LocalizationHelper.localized("Approaching the limit. Your ride will split automatically at 9,000 points.")
        content.sound = .default
        let request = UNNotificationRequest(identifier: "LongRideWarning", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func showAutoSplitNotification() {
        let content = UNMutableNotificationContent()
        content.title = LocalizationHelper.localized("Ride Auto-Split")
        content.body = LocalizationHelper.localized("Your ride reached 9,000 points and was split automatically.")
        content.sound = .default
        let request = UNNotificationRequest(identifier: "RideAutoSplit", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
