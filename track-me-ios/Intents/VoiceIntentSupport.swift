import Foundation

/// Immutable data made available to an App Intent invocation. Keeping the framework adapter on
/// the main actor serializes overlapping Siri commands and keeps formatting independent of Core
/// Location, SwiftData, PostHog, and App Intents.
struct VoiceRideSnapshot: Equatable {
    let rideID: UUID?
    let state: TrackingState
    let persona: RidePersona
    let distanceMeters: Double
    let speedMps: Double
    let movingDurationMillis: TimeInterval

    var hasActiveRide: Bool {
        rideID != nil && state != .idle
    }
}

@MainActor
protocol VoiceIntentEnvironment: AnyObject {
    var rideSnapshot: VoiceRideSnapshot { get }

    @discardableResult func startRide(persona: RidePersona) -> Bool
    func pauseRide()
    func resumeRide()
    func endRide()
    func trackVoiceEvent(_ event: VoiceTelemetryEvent)
}

@MainActor
final class LiveVoiceIntentEnvironment: VoiceIntentEnvironment {
    static let shared = LiveVoiceIntentEnvironment()

    private let trackingManager: TrackingManager
    private let telemetryManager: TelemetryManager

    private init(
        trackingManager: TrackingManager = .shared,
        telemetryManager: TelemetryManager = .shared
    ) {
        self.trackingManager = trackingManager
        self.telemetryManager = telemetryManager
    }

    var rideSnapshot: VoiceRideSnapshot {
        VoiceRideSnapshot(
            rideID: trackingManager.currentRideId,
            state: trackingManager.state,
            persona: trackingManager.selectedPersona,
            distanceMeters: trackingManager.totalDistance,
            speedMps: trackingManager.currentSpeed,
            movingDurationMillis: trackingManager.durationInMillis
        )
    }

    func startRide(persona: RidePersona) -> Bool {
        trackingManager.startTrackingFromVoice(persona: persona)
    }

    func pauseRide() {
        trackingManager.pauseTracking()
    }

    func resumeRide() {
        trackingManager.resumeTracking()
    }

    func endRide() {
        trackingManager.stopTracking()
    }

    func trackVoiceEvent(_ event: VoiceTelemetryEvent) {
        telemetryManager.trackVoiceEvent(event)
    }
}

enum VoiceIntentActionDecision: Equatable {
    case execute(requiresConfirmation: Bool)
    case reject(VoiceFailureReason)
}

/// State gating is pure so a Pause or Resume invocation can never fall through to Start.
enum VoiceIntentActionPolicy {
    static func decide(action: VoiceAction, snapshot: VoiceRideSnapshot) -> VoiceIntentActionDecision {
        switch action {
        case .start:
            snapshot.hasActiveRide ? .reject(.invalidRideState) : .execute(requiresConfirmation: false)
        case .pause:
            switch snapshot.state {
            case .idle:
                .reject(.noActiveRide)
            case .tracking, .gpsLost:
                snapshot.hasActiveRide
                    ? .execute(requiresConfirmation: false)
                    : .reject(.noActiveRide)
            case .paused, .storageLow:
                .reject(.invalidRideState)
            }
        case .resume:
            switch snapshot.state {
            case .idle:
                .reject(.noActiveRide)
            case .paused:
                snapshot.hasActiveRide
                    ? .execute(requiresConfirmation: false)
                    : .reject(.noActiveRide)
            case .tracking, .gpsLost, .storageLow:
                .reject(.invalidRideState)
            }
        case .end:
            snapshot.hasActiveRide
                ? .execute(requiresConfirmation: true)
                : .reject(.noActiveRide)
        }
    }
}

struct VoiceIntentResponse: Equatable {
    let dialog: String
    let failureReason: VoiceFailureReason?

    static func success(_ dialog: String) -> VoiceIntentResponse {
        VoiceIntentResponse(dialog: dialog, failureReason: nil)
    }

    static func failure(_ reason: VoiceFailureReason, dialog: String) -> VoiceIntentResponse {
        VoiceIntentResponse(dialog: dialog, failureReason: reason)
    }
}

@MainActor
struct VoiceActionIntentPerformer {
    let environment: any VoiceIntentEnvironment

    func perform(
        action: VoiceAction,
        persona: RidePersona = .auto,
        unit: UnitSystem = UnitPreference.current,
        confirm: ((String) async throws -> Void)? = nil
    ) async throws -> VoiceIntentResponse {
        environment.trackVoiceEvent(
            VoiceTelemetryContract.commandInvoked(intent: action.intent, surface: .assistant)
        )

        let initialSnapshot = environment.rideSnapshot
        switch VoiceIntentActionPolicy.decide(action: action, snapshot: initialSnapshot) {
        case let .reject(reason):
            return reject(action: action, reason: reason)
        case let .execute(requiresConfirmation):
            if requiresConfirmation {
                guard let confirm else {
                    return reject(action: action, reason: .unavailable)
                }
                try await confirm(VoiceSpokenCopy.endConfirmation(snapshot: initialSnapshot, unit: unit))

                // App Intent confirmation suspends this main-actor task. Revalidate the exact ride
                // so a late "yes" can never end a replacement ride started during the prompt.
                let confirmedSnapshot = environment.rideSnapshot
                guard confirmedSnapshot.hasActiveRide,
                      confirmedSnapshot.rideID == initialSnapshot.rideID else {
                    return reject(action: action, reason: .invalidRideState)
                }
            }

            return execute(action: action, persona: persona)
        }
    }

    private func execute(action: VoiceAction, persona: RidePersona) -> VoiceIntentResponse {
        switch action {
        case .start:
            guard environment.startRide(persona: persona) else {
                return reject(action: action, reason: .unavailable)
            }
            return .success(VoiceSpokenCopy.rideStarted(persona: persona))
        case .pause:
            environment.pauseRide()
            return .success(VoiceSpokenCopy.ridePaused)
        case .resume:
            environment.resumeRide()
            return .success(VoiceSpokenCopy.rideResumed)
        case .end:
            environment.endRide()
            return .success(VoiceSpokenCopy.rideSaved)
        }
    }

    private func reject(action: VoiceAction, reason: VoiceFailureReason) -> VoiceIntentResponse {
        environment.trackVoiceEvent(
            VoiceTelemetryContract.commandFailed(intent: action.intent, reason: reason)
        )
        return .failure(reason, dialog: VoiceSpokenCopy.failure(reason))
    }
}

@MainActor
struct VoicePersonalQueryIntentPerformer {
    let environment: any VoiceIntentEnvironment

    func perform(query: VoicePersonalQuery, unit: UnitSystem) -> VoiceIntentResponse {
        environment.trackVoiceEvent(
            VoiceTelemetryContract.commandInvoked(intent: query.intent, surface: .assistant)
        )

        let snapshot = environment.rideSnapshot
        guard snapshot.hasActiveRide else {
            let reason = VoiceFailureReason.noActiveRide
            environment.trackVoiceEvent(
                VoiceTelemetryContract.commandFailed(intent: query.intent, reason: reason)
            )
            return .failure(reason, dialog: VoiceSpokenCopy.noActiveRide)
        }

        let freshness: VoiceFreshnessBucket = snapshot.state == .gpsLost ? .unknown : .now
        environment.trackVoiceEvent(
            VoiceTelemetryContract.queryAnswered(intent: query.queryIntent, freshness: freshness)
        )
        return .success(VoiceSpokenCopy.personalQuery(query, snapshot: snapshot, unit: unit))
    }
}

/// TASK-196 owns the catalogue entries and its cross-platform consumer guard. These call sites use
/// only `voice*` keys, force the deliberate HANDSFREE-01 English locale, and include safe defaults
/// so this feature branch remains independently runnable before TASK-196 is integrated.
enum VoiceSpokenCopy {
    private static let englishLocale = Locale(identifier: "en_GB")

    static var noActiveRide: String {
        localized(
            "voiceNoActiveRide",
            defaultValue: "You don't have a ride recording right now."
        )
    }

    static var ridePaused: String {
        localized("voiceRidePaused", defaultValue: "Ride paused.")
    }

    static var rideResumed: String {
        localized("voiceRideResumed", defaultValue: "Ride resumed.")
    }

    static var rideSaved: String {
        localized("voiceRideSaved", defaultValue: "Ride saved.")
    }

    static func rideStarted(persona: RidePersona) -> String {
        if persona == .auto {
            return localized("voiceRideStarted", defaultValue: "Ride recording started.")
        }
        return format(
            "voicePersonaRideStarted",
            defaultValue: "%@ recording started.",
            persona.displayName
        )
    }

    static func failure(_ reason: VoiceFailureReason) -> String {
        switch reason {
        case .noActiveRide:
            noActiveRide
        case .invalidRideState:
            localized(
                "voiceInvalidRideState",
                defaultValue: "That action isn't available for your ride right now."
            )
        case .locked:
            localized("voiceUnlockRequired", defaultValue: "Unlock your phone and I'll tell you.")
        case .noActiveGroup, .emptyCache, .degraded, .memberNotFound, .ambiguousMember, .unavailable:
            localized("voiceCommandUnavailable", defaultValue: "I can't do that right now.")
        }
    }

    static func endConfirmation(snapshot: VoiceRideSnapshot, unit: UnitSystem) -> String {
        format(
            "voiceEndRideConfirm",
            defaultValue: "You've recorded %@ in %@. End the ride?",
            distance(snapshot.distanceMeters, unit: unit),
            duration(snapshot.movingDurationMillis)
        )
    }

    static func personalQuery(
        _ query: VoicePersonalQuery,
        snapshot: VoiceRideSnapshot,
        unit: UnitSystem
    ) -> String {
        switch query {
        case .distance:
            return distanceQuery(snapshot: snapshot, unit: unit)
        case .paceOrSpeed:
            return movementQuery(snapshot: snapshot, unit: unit)
        case .duration:
            let state = snapshot.state == .paused || snapshot.state == .storageLow
                ? localized("voiceRideStatePaused", defaultValue: "paused")
                : localized("voiceRideStateMoving", defaultValue: "moving")
            return format(
                "voiceDuration",
                defaultValue: "%@, %@.",
                duration(snapshot.movingDurationMillis),
                state
            )
        }
    }

    private static func distanceQuery(snapshot: VoiceRideSnapshot, unit: UnitSystem) -> String {
        let spokenDistance = distance(snapshot.distanceMeters, unit: unit)
        switch snapshot.state {
        case .gpsLost:
            return format(
                "voiceDistanceGpsLost",
                defaultValue: "%@. I'm still looking for GPS, so that may be behind.",
                spokenDistance
            )
        case .paused, .storageLow:
            return format(
                "voiceDistancePaused",
                defaultValue: "%@. Your ride is paused.",
                spokenDistance
            )
        case .idle, .tracking:
            return format("voiceDistanceSoFar", defaultValue: "%@ so far.", spokenDistance)
        }
    }

    private static func movementQuery(snapshot: VoiceRideSnapshot, unit: UnitSystem) -> String {
        if snapshot.state == .gpsLost {
            return localized(
                "voiceMovementGpsLost",
                defaultValue: "I don't have a current pace or speed while GPS is unavailable."
            )
        }

        if snapshot.persona == .walk || snapshot.persona == .run {
            guard let pace = pace(snapshot.speedMps, unit: unit) else {
                return localized("voicePaceUnavailable", defaultValue: "I don't have a current pace yet.")
            }
            return pace + "."
        }
        return speed(snapshot.speedMps, unit: unit) + "."
    }

    static func distance(_ meters: Double, unit: UnitSystem) -> String {
        let value = meters / (unit == .metric ? 1_000 : 1_609.344)
        let rounded = (value * 10).rounded() / 10
        let unitName: String
        if unit == .metric {
            unitName = rounded == 1 ? "kilometre" : "kilometres"
        } else {
            unitName = rounded == 1 ? "mile" : "miles"
        }
        return "\(spell(rounded, maximumFractionDigits: 1)) \(unitName)"
    }

    static func speed(_ metersPerSecond: Double, unit: UnitSystem) -> String {
        let value = metersPerSecond * (unit == .metric ? 3.6 : 2.236_936)
        let rounded = (value * 10).rounded() / 10
        let unitName = unit == .metric ? "kilometres per hour" : "miles per hour"
        return "\(spell(rounded, maximumFractionDigits: 1)) \(unitName)"
    }

    static func pace(_ metersPerSecond: Double, unit: UnitSystem) -> String? {
        guard metersPerSecond >= 0.2 else { return nil }
        let metersPerUnit = unit == .metric ? 1_000.0 : 1_609.344
        let totalSeconds = min(Int((metersPerUnit / metersPerSecond).rounded()), 99 * 60 + 59)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        let unitName = unit == .metric ? "kilometre" : "mile"
        let minuteUnit = minutes == 1 ? "minute" : "minutes"
        if seconds == 0 {
            return "\(spell(minutes)) \(minuteUnit) per \(unitName)"
        }
        let secondUnit = seconds == 1 ? "second" : "seconds"
        return "\(spell(minutes)) \(minuteUnit) \(spell(seconds)) \(secondUnit) per \(unitName)"
    }

    static func duration(_ milliseconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int((milliseconds / 1_000).rounded()))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        var parts: [String] = []
        if hours > 0 {
            parts.append("\(spell(hours)) \(hours == 1 ? "hour" : "hours")")
        }
        if minutes > 0 {
            parts.append("\(spell(minutes)) \(minutes == 1 ? "minute" : "minutes")")
        }
        if parts.isEmpty || (hours == 0 && seconds > 0) {
            parts.append("\(spell(seconds)) \(seconds == 1 ? "second" : "seconds")")
        }
        return parts.joined(separator: " ")
    }

    private static func spell(_ value: Int) -> String {
        spell(Double(value), maximumFractionDigits: 0)
    }

    private static func spell(_ value: Double, maximumFractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = englishLocale
        formatter.numberStyle = .spellOut
        formatter.maximumFractionDigits = maximumFractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func localized(
        _ key: StaticString,
        defaultValue: String.LocalizationValue
    ) -> String {
        String(
            localized: key,
            defaultValue: defaultValue,
            table: "Localizable",
            bundle: .main,
            locale: englishLocale
        )
    }

    private static func format(
        _ key: StaticString,
        defaultValue: String.LocalizationValue,
        _ arguments: CVarArg...
    ) -> String {
        String(
            format: localized(key, defaultValue: defaultValue),
            locale: englishLocale,
            arguments: arguments
        )
    }
}
