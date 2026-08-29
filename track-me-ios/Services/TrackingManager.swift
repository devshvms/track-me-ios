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

/// CLLocationManager settings that define a recorded ride session.
///
/// Keeping this descriptor separate from the framework object makes the
/// reliability invariants testable without requiring a physical device.
struct LocationSessionConfig {
    var desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyBest
    var distanceFilter: CLLocationDistance = 2
    var allowsBackgroundLocationUpdates = true
    var showsBackgroundLocationIndicator = true
    var activityType: CLActivityType = .fitness
    /// TrackMe owns pause detection; Core Location must not silently stop the stream.
    var pausesLocationUpdatesAutomatically = false

    static let recordingRide = LocationSessionConfig()
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
    var maxSpeedMps: Double = 0.0
    var durationInMillis: TimeInterval = 0
    var elapsedDurationInMillis: TimeInterval = 0
    var selectedPersona: RidePersona = .auto
    var isAutoPaused: Bool = false
    var timeSinceLastGps: TimeInterval = 0
    var lastGpsTimestamp: Date?
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
    private var lastStorageCheck = Date.distantPast
    private var skipsNextDistanceSegmentAfterManualPause = false

    override init() {
        super.init()
        locationManager.delegate = self
        let config = LocationSessionConfig.recordingRide
        locationManager.desiredAccuracy = config.desiredAccuracy
        locationManager.distanceFilter = config.distanceFilter
        locationManager.allowsBackgroundLocationUpdates = config.allowsBackgroundLocationUpdates
        locationManager.showsBackgroundLocationIndicator = config.showsBackgroundLocationIndicator
        // TrackMe records a continuous ride; do NOT let Core Location pause the
        // stream on its own judgement — it often fails to auto-resume, silently
        // truncating a ride in the background. We stop updates explicitly in
        // stopTracking()/enterStorageLowState(). activityType tunes the location
        // engine for human-powered movement (parity with Android's continuous FGS).
        locationManager.activityType = config.activityType
        locationManager.pausesLocationUpdatesAutomatically = config.pausesLocationUpdatesAutomatically
    }

    static func activityType(for persona: RidePersona) -> CLActivityType {
        switch persona {
        case .bikeDrive, .carDrive:
            .automotiveNavigation
        case .cycling:
            .otherNavigation
        case .auto, .walk, .run:
            .fitness
        }
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

    func startTracking(persona: RidePersona = .auto) {
        selectedPersona = persona
        switch LocationStartDecision.action(for: mappedAuth) {
        case .requestWhenInUse:
            pendingTrackingStart = true
            locationManager.requestWhenInUseAuthorization()
        case .begin:
            beginTracking()
            requestAlwaysUpgradeIfAppropriate()
        case .deniedRecovery:
            pendingTrackingStart = false
            selectedPersona = .auto
            offerDeniedRecovery()
        }
    }

    /// Starts a ride only when the command can complete without presenting permission UI.
    ///
    /// App Intents execute while another app may own the screen. Asking for location permission
    /// from that background execution would neither be headless nor reliably actionable, so Siri
    /// reports the command as unavailable until the rider has granted permission in TrackMe. The
    /// voice path also suppresses the normal tracking-notification permission request.
    @MainActor
    @discardableResult
    func startTrackingFromVoice(persona: RidePersona) -> Bool {
        guard state == .idle, currentRideId == nil else { return false }
        guard mappedAuth == .whenInUse || mappedAuth == .always else { return false }

        // Do not call startTracking here: its normal in-app path may request the Always upgrade.
        // Siri must never present permission UI over the rider's navigation app.
        selectedPersona = persona
        beginTracking(allowsPermissionPrompts: false)
        let didStart = state != .idle && currentRideId != nil
        if !didStart {
            selectedPersona = .auto
        }
        return didStart
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if GroupRideManager.shared.state.isActive,
           mappedAuth == .denied || mappedAuth == .restricted {
            GroupRideManager.shared.updateLatestLocation(nil, moving: false, riding: currentRideId != nil)
        }
        guard pendingTrackingStart else { return }
        switch mappedAuth {
        case .whenInUse, .always:
            beginTracking()
            requestAlwaysUpgradeIfAppropriate()
        case .denied, .restricted:
            pendingTrackingStart = false
            selectedPersona = .auto
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

    private func beginTracking(allowsPermissionPrompts: Bool = true) {
        pendingTrackingStart = false

        // Refuse to start if the device can't reliably persist points.
        if StorageHealthMonitor.isLowStorage() {
            ToastManager.shared.show(
                message: LocalizationHelper.localized("Not enough free storage to start tracking. Free up space and try again."),
                style: .error
            )
            return
        }

        // Open a fresh legacy-emergency suppression window before the ride exists. A restored ride
        // deliberately does NOT call this (see restoreInterruptedSessionIfNeeded) — it keeps any
        // persisted compatibility bit until finalization.
        EmergencyManager.shared.beginRideSession()

        locationManager.activityType = Self.activityType(for: selectedPersona)
        let rideStartTime = Date()
        let newRide = Ride(
            startTime: rideStartTime,
            title: RideTitleGenerator.make(
                startTime: rideStartTime,
                persona: selectedPersona,
                maxSpeedKmh: nil
            )
        )
        newRide.persona = selectedPersona.rawValue
        newRide.startZoneId = TimeZone.current.identifier
        // TASK-232: was a group live when this ride began? A marker and a count, never a group id
        // and never a name — see Ride's note. The roster may not have synced yet at start, so an
        // empty one stores no count rather than a zero, and finalisation widens it if a session is
        // still live then.
        let groupAtStart = GroupRideManager.shared.state
        newRide.wasGroupRide = groupAtStart.isActive
        newRide.groupRiderCount = groupAtStart.isActive && groupAtStart.memberCount > 0
            ? groupAtStart.memberCount
            : nil
        currentRideId = newRide.id
        UserDefaults.standard.set(newRide.id.uuidString, forKey: Self.activeRideKey)
        GroupRideManager.shared.refreshLocationSource()

        // Reset live state for a fresh ride.
        storageWarningShown = false
        lastStorageCheck = Date.distantPast
        state = .tracking
        points.removeAll(keepingCapacity: false)
        currentSpeed = 0.0
        totalDistance = 0.0
        maxSpeedMps = 0.0
        durationInMillis = 0
        elapsedDurationInMillis = 0
        skipsNextDistanceSegmentAfterManualPause = false
        timeSinceLastGps = 0
        lastGpsTimestamp = Date()

        TelemetryManager.shared.trackRideStarted()

        // Save initially on main thread
        DispatchQueue.main.async {
            if DataRepository.shared.saveRide(newRide) {
                // Selection and permission attempts are intentionally not persisted. This changes
                // only after the recording row commits locally.
                DashboardPersonaPreference.recordCommittedStart(newRide.ridePersona)
            }
        }

        startLocationUpdatesAndTimer(allowsPermissionPrompts: allowsPermissionPrompts)
        RideActivityManager.shared.startActivity(rideId: newRide.id.uuidString, startedAt: rideStartTime)
    }

    /// Shared session bring-up used by both a fresh ride and a restored one.
    private func startLocationUpdatesAndTimer(allowsPermissionPrompts: Bool = true) {
        locationManager.startUpdatingLocation()
        if MotionSensorManager.isMotionFusionEnabled {
            motionSensor.startListening()
        }
        if allowsPermissionPrompts {
            requestTrackingNotification()
        }
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
            if self.state != .idle {
                self.elapsedDurationInMillis += 1000
            }
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
        let restoredAggregate = RideMetrics.reconstructed(from: sorted)
        totalDistance = restoredAggregate.distanceMeters
        durationInMillis = Double(restoredAggregate.movingDurationMillis)
        elapsedDurationInMillis = max(0, Date().timeIntervalSince(ride.startTime)) * 1000
        selectedPersona = ride.ridePersona
        locationManager.activityType = Self.activityType(for: selectedPersona)
        lastGpsTimestamp = last.timestamp
        timeSinceLastGps = Date().timeIntervalSince(last.timestamp)
        currentSpeed = 0.0
        maxSpeedMps = restoredAggregate.maxSpeedMps
        // A manual-pause boundary is persisted even if the app dies before the next fix. Keep the
        // live accumulator aligned with RideMetrics.reconstructed when that ride is restored.
        skipsNextDistanceSegmentAfterManualPause = last.isPaused
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
            finalizeSegment(id: id, endedAt: Date())
        }
        currentRideId = nil
        elapsedDurationInMillis = 0
        skipsNextDistanceSegmentAfterManualPause = false
        selectedPersona = .auto
        locationManager.activityType = LocationSessionConfig.recordingRide.activityType
        GroupRideManager.shared.refreshLocationSource()

        // Stop live sharing when the ride ends
        if LiveSharingManager.shared.isActive && LiveSharingManager.shared.isRideLinked {
            LiveSharingManager.shared.stopSession(reason: "Ride ended successfully.")
        }
    }

    /// Cancels a just-started ride without finalization, cloud sync, or post-ride surfaces.
    /// The policy is checked again here so a stale UI affordance cannot discard a real ride.
    @discardableResult
    func discardNearEmptyRideStart() -> Bool {
        guard state != .idle,
              let id = currentRideId,
              RideStartAbortPolicy.canOfferPostCommitUndo(
                durationInMillis: durationInMillis,
                distanceMeters: totalDistance
              ) else { return false }

        locationManager.stopUpdatingLocation()
        motionSensor.stopListening()
        timer?.invalidate()
        timer = nil
        storageWarningShown = false
        state = .idle
        UserDefaults.standard.removeObject(forKey: Self.activeRideKey)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["StorageLow"])

        RideActivityManager.shared.end(
            startedAt: Date().addingTimeInterval(-durationInMillis / 1000),
            distanceMeters: totalDistance,
            speedMps: 0,
            pausedElapsed: durationInMillis / 1000
        )

        // Consume the legacy suppression bit just as normal finalization does, but deliberately
        // skip finishRide/ride_completed/reveal generation for an explicit start abort.
        _ = EmergencyManager.shared.consumeRideSuppression()
        DataRepository.shared.deleteRide(rideId: id)
        currentRideId = nil
        GroupRideManager.shared.refreshLocationSource()
        points.removeAll(keepingCapacity: false)
        currentSpeed = 0
        totalDistance = 0
        maxSpeedMps = 0
        durationInMillis = 0
        elapsedDurationInMillis = 0
        selectedPersona = .auto
        locationManager.activityType = LocationSessionConfig.recordingRide.activityType
        isAutoPaused = false
        timeSinceLastGps = 0
        lastGpsTimestamp = nil

        if LiveSharingManager.shared.isActive && LiveSharingManager.shared.isRideLinked {
            LiveSharingManager.shared.stopSession(reason: "Ride start cancelled.")
        }
        return true
    }

    func pauseTracking() {
        if state == .tracking || state == .gpsLost || state == .storageLow {
            // TASK-257, shvm: record *that* the pause happened, at the place it happened.
            //
            // A manual pause used to leave nothing behind. Recording stopped, so the fix before and
            // the fix after ended up adjacent in storage with the pause flag clear on both, and
            // every consumer read the jump between them as travel -- distance counted, and a
            // straight line drawn through buildings the rider never rode past.
            //
            // Auto-pause never had this problem because it flags its points. This gives a manual
            // pause the same evidence, and it is a real position rather than a synthetic one: where
            // the rider was when they pressed pause. One marker is enough -- carrying `isPaused`,
            // it excludes *both* segments touching it, the one into the pause and the one out.
            skipsNextDistanceSegmentAfterManualPause = true
            markPauseBoundary()
            state = .paused
            currentSpeed = 0.0
            updateLiveActivity(force: true)
        }
    }

    /// Writes the current position as a paused point, so the pause is visible in the point stream.
    ///
    /// Best-effort: with no last fix there is nothing truthful to write, and inventing a position
    /// would be worse than leaving the gap — the gap is at least honest, and the renderer's
    /// time-and-speed rule still dots it.
    private func markPauseBoundary() {
        guard let rideId = currentRideId, let last = points.last else { return }
        DataRepository.shared.savePointBackground(
            rideId: rideId,
            lat: last.coordinate.latitude,
            lng: last.coordinate.longitude,
            alt: last.altitude,
            acc: last.horizontalAccuracy,
            spd: 0,
            ts: Date(),
            paused: true
        )
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
            maxSpeedMps = max(maxSpeedMps, effectiveSpeed)
            // The persisted pause marker excludes the segment to this first accepted fix. Mirror
            // that rule in the live aggregate so the HUD and finalized ride never count movement
            // that happened while recording was manually paused.
            let crossesManualPause = skipsNextDistanceSegmentAfterManualPause
            skipsNextDistanceSegmentAfterManualPause = false
            if MotionSensorManager.distanceShouldAccumulate(
                state: accumulationState,
                isPaused: isPaused,
                crossesManualPause: crossesManualPause,
                dist: dist,
                effectiveSpeed: effectiveSpeed
            ) {
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

            if GroupRideManager.shared.state.isActive {
                GroupRideManager.shared.updateLatestLocation(
                    smoothedLocation,
                    moving: effectiveSpeed > 0.5,
                    riding: currentRideId != nil
                )
            }

        }

        // Live Activity (throttled; forced when we just regained GPS).
        updateLiveActivity(force: recoveredFromGpsLost)
    }

    // MARK: - Finalization Helpers

    /// Finalize the ride identified by `id` using the authoritative in-memory
    /// segment distance/duration. Keeping finalization in one path ensures the
    /// A1 good-ride hook and telemetry fire consistently when recording stops.
    private func finalizeSegment(id: UUID, endedAt: Date) {
        // Consume the single legacy suppression bit before the junk-ride early return, so a
        // discarded segment cannot leave it set for the next ride. History still records a valid
        // ride, while old upgraded data cannot create a reveal unexpectedly.
        let suppressPostRideCelebrations = EmergencyManager.shared.consumeRideSuppression()

        let aggregate = RideAggregateSnapshot.live(
            distanceMeters: totalDistance,
            movingDurationMillis: durationInMillis,
            maxSpeedMps: maxSpeedMps,
            pointCount: points.count,
            elevationGainMeters: RideMetrics.elevationGainMeters(fromLocations: points)
        )
        DataRepository.shared.finishRide(rideId: id, endedAt: endedAt, aggregate: aggregate)
        TelemetryManager.shared.trackRideCompleted()

        let isJunk = totalDistance < 10.0 && durationInMillis < 2 * 60 * 1000
        if !isJunk {
            let summary = GoodRideSummary(
                rideId: id.uuidString,
                finishedAtMillis: Int64(endedAt.timeIntervalSince1970 * 1000),
                durationMillis: Int64(durationInMillis),
                distanceMeters: totalDistance,
                suppressPostRideCelebrations: suppressPostRideCelebrations
            )
            Task {
                let transition = await RideStatsStore.shared.recordGoodRide(summary)
                if transition.isFirstRideOfWeek {
                    TelemetryManager.shared.trackWeeklyStreakUpdated(
                        streakWeeks: transition.streakWeeks, froze: transition.streakFroze)
                }
                if let reveal = RevealSelector.select(transition) {
                    RevealCoordinator.shared.put(reveal)
                }
            }
        } else {
            ToastManager.shared.show(message: LocalizationHelper.localized("Ride saved successfully"), style: .success)
        }
    }

}
