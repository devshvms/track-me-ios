import Foundation

/**
 * TASK-371..373 (v1.9.4): Unified Hands-Free Reliability State Machine & Privacy-Safe Telemetry Contract.
 *
 * Pure policy functions shared by `TrackingManager`, `HomeView`, `HomeDashboardDeck`, and unit tests
 * with 100% parity with Android's `HandsFreeReliabilityPolicy.kt`:
 *  1. Wall-clock elapsed time classification for post-commit undo and short indoor tests.
 *  2. 1Hz timer-driven DwellDetector evaluation under 3-minute stationary GPS throttling.
 *  3. False `.gpsLost` / `location_updates_paused` suppression while stationary and throttled.
 *  4. Immediate hardware un-throttling on motion sensor wake.
 *  5. Active Live Share suppressing dwell auto-end.
 *  6. 2-hour standby window backed by a persisted expiry timestamp enforced on timer ticks,
 *     Core Location wakes, and app lifecycle/time-change wakes (iOS may suspend run-loop timers
 *     while the app is backgrounded).
 */
enum HandsFreeReliabilityPolicy {
    static let standbyTimeoutMinutes: Int = 120
    static let standbyExpiresAtKey: String = "handsFreeStandbyExpiresAt"

    /// Computes the wall-clock expiry deadline for a standby session.
    static func standbyExpiryDate(startedAt: Date, maxWindow: TimeInterval) -> Date {
        startedAt.addingTimeInterval(max(1, maxWindow))
    }

    /// Returns true once the persisted or in-memory standby deadline has been reached or passed.
    static func isStandbyExpired(expiresAt: Date?, now: Date) -> Bool {
        guard let expiresAt else { return false }
        return now >= expiresAt
    }

    /// Reads the persisted standby expiry timestamp across background suspension or relaunch.
    static func persistedStandbyExpiry(defaults: UserDefaults = .standard) -> Date? {
        guard defaults.object(forKey: standbyExpiresAtKey) != nil else { return nil }
        let epoch = defaults.double(forKey: standbyExpiresAtKey)
        guard epoch > 0 else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }

    /// Persists or clears the standby expiry deadline so every lifecycle/location wake can enforce it.
    static func persistStandbyExpiry(_ expiresAt: Date?, defaults: UserDefaults = .standard) {
        if let expiresAt {
            defaults.set(expiresAt.timeIntervalSince1970, forKey: standbyExpiresAtKey)
        } else {
            defaults.removeObject(forKey: standbyExpiresAtKey)
        }
    }

    /// Invariants 2 & 5: Evaluate DwellDetector on the 1Hz tracking timer whenever Hands-Free is
    /// enabled, Live Share is not active/starting, and the device is stationary, throttled, or
    /// already dwelling indoors so 5/10/15/30-min Auto-End fires deterministically without needing
    /// a new OS CoreLocation callback.
    static func shouldEvaluateDwellOnTimerTick(
        isAutoTripChainingEnabled: Bool,
        isLiveShareBlockingDwell: Bool,
        isAutoPaused: Bool,
        isMotionStationary: Bool,
        isGpsThrottled: Bool,
        dwellState: DwellState
    ) -> Bool {
        guard isAutoTripChainingEnabled, !isLiveShareBlockingDwell else { return false }
        return isAutoPaused || isMotionStationary || isGpsThrottled || dwellState == .dwelling
    }

    /// Invariant 3: Suppress false `.gpsLost` transitions and `location_updates_paused` telemetry
    /// while stationary GPS throttling (`distanceFilter = 15m`) intentionally suppresses callbacks.
    static func shouldSuppressGpsLost(
        isGpsThrottled: Bool,
        isStationary: Bool
    ) -> Bool {
        isGpsThrottled && isStationary
    }

    /// Invariant 4: Restore high-accuracy polling immediately when hardware motion resumes.
    static func shouldUnthrottleOnMotionWake(
        isGpsThrottled: Bool,
        isMotionStationary: Bool,
        hasMotionSample: Bool = true
    ) -> Bool {
        guard hasMotionSample else { return false }
        return AdaptiveGpsThrottlePolicy.shouldRestore(
            isCurrentlyThrottled: isGpsThrottled,
            isStationary: isMotionStationary
        )
    }

    /// Anti-duplication rule for the single top banner slot on Home:
    /// never stack the Hands-Free discovery card with standby mode or an unread operator broadcast.
    static func shouldShowHomeHandsFreeTip(
        isStandbyActive: Bool,
        autoTripChainingEnabled: Bool,
        tipDismissed: Bool,
        hasUnreadBroadcast: Bool = false
    ) -> Bool {
        !isStandbyActive && !autoTripChainingEnabled && !tipDismissed && !hasUnreadBroadcast
    }
}

struct HandsFreeTelemetryEvent {
    let name: String
    let properties: [String: Any]
}

/// Privacy-safe PostHog contract for TASK-371..373 (§3.2).
/// Strictly contains zero coordinates, zero user identifiers, and zero ride titles.
enum HandsFreeTelemetryContract {
    static let offerSurfaces: Set<String> = ["discard_dialog", "home_top_slot", "post_ride_reveal"]
    static let enableSurfaces: Set<String> = ["discard_dialog", "home_top_slot", "post_ride_reveal", "settings"]
    static let disableSurfaces: Set<String> = ["standby_banner", "settings"]
    static let standbyTriggers: Set<String> = ["indoor_test_discard", "auto_end_dwell", "home_opt_in"]

    static func offerShown(surface: String) -> HandsFreeTelemetryEvent {
        precondition(offerSurfaces.contains(surface), "Unsupported hands_free_offer_shown surface: \(surface)")
        return HandsFreeTelemetryEvent(
            name: "hands_free_offer_shown",
            properties: ["surface": surface]
        )
    }

    static func enabled(surface: String, dwellMinutes: Int) -> HandsFreeTelemetryEvent {
        precondition(enableSurfaces.contains(surface), "Unsupported hands_free_enabled surface: \(surface)")
        return HandsFreeTelemetryEvent(
            name: "hands_free_enabled",
            properties: [
                "surface": surface,
                "dwell_minutes": max(1, min(60, dwellMinutes))
            ]
        )
    }

    static func disabled(surface: String) -> HandsFreeTelemetryEvent {
        precondition(disableSurfaces.contains(surface), "Unsupported hands_free_disabled surface: \(surface)")
        return HandsFreeTelemetryEvent(
            name: "hands_free_disabled",
            properties: ["surface": surface]
        )
    }

    static func standbyArmed(
        trigger: String,
        timeoutMinutes: Int = HandsFreeReliabilityPolicy.standbyTimeoutMinutes
    ) -> HandsFreeTelemetryEvent {
        precondition(standbyTriggers.contains(trigger), "Unsupported hands_free_standby_armed trigger: \(trigger)")
        return HandsFreeTelemetryEvent(
            name: "hands_free_standby_armed",
            properties: [
                "trigger": trigger,
                "timeout_minutes": max(1, timeoutMinutes)
            ]
        )
    }

    static func rideAutoStarted(standbyWaitSeconds: Int, activityType: String) -> HandsFreeTelemetryEvent {
        let trimmed = activityType.trimmingCharacters(in: .whitespacesAndNewlines)
        return HandsFreeTelemetryEvent(
            name: "hands_free_ride_auto_started",
            properties: [
                "standby_wait_seconds": max(0, standbyWaitSeconds),
                "activity_type": trimmed.isEmpty ? "AUTO" : trimmed
            ]
        )
    }

    static func rideAutoEnded(
        dwellMinutes: Int,
        croppedPoints: Int,
        wasGpsThrottled: Bool
    ) -> HandsFreeTelemetryEvent {
        HandsFreeTelemetryEvent(
            name: "hands_free_ride_auto_ended",
            properties: [
                "dwell_minutes": max(1, min(60, dwellMinutes)),
                "cropped_points": max(0, croppedPoints),
                "was_gps_throttled": wasGpsThrottled
            ]
        )
    }

    static func falseStartAborted(elapsedSeconds: Int, distanceMeters: Int) -> HandsFreeTelemetryEvent {
        HandsFreeTelemetryEvent(
            name: "hands_free_false_start_aborted",
            properties: [
                "elapsed_seconds": max(0, elapsedSeconds),
                "distance_meters": max(0, distanceMeters)
            ]
        )
    }

    static var privacySamples: [HandsFreeTelemetryEvent] {
        [
            offerShown(surface: "discard_dialog"),
            enabled(surface: "home_top_slot", dwellMinutes: 10),
            disabled(surface: "standby_banner"),
            standbyArmed(trigger: "indoor_test_discard", timeoutMinutes: 120),
            rideAutoStarted(standbyWaitSeconds: 1800, activityType: "AUTO"),
            rideAutoEnded(dwellMinutes: 10, croppedPoints: 24, wasGpsThrottled: true),
            falseStartAborted(elapsedSeconds: 25, distanceMeters: 12)
        ]
    }
}
