import Foundation
import SwiftUI
import PostHog
import FirebaseFirestore

/// Pure consent contract shared with Android: local opt-in is required, while the
/// remote flag can only force telemetry off.
struct TelemetryConsentState {
    let localConsent: Bool
    let remoteAllowed: Bool

    var isEnabled: Bool { localConsent && remoteAllowed }
}

enum GroupJoinFailure: String, CaseIterable {
    case malformedCode = "malformed_code"
    case expired
    case groupFull = "group_full"
    case groupNotFound = "group_not_found"
    case joinRateLimited = "join_rate_limited"
    case signedOut = "signed_out"
    case network
    case unknown
}

enum GroupDirectionsAgeBucket: String, CaseIterable {
    case now
    case seconds
    case minutes
    case hours
    case unknown
}

struct GroupTelemetryEvent {
    let name: String
    let properties: [String: Any]?
}

enum GroupTelemetryContract {
    static func inviteSent() -> GroupTelemetryEvent {
        GroupTelemetryEvent(name: "group_invite_sent", properties: nil)
    }

    static func inviteOpened(viaCode: Bool) -> GroupTelemetryEvent {
        GroupTelemetryEvent(name: "group_invite_opened", properties: ["via_code": viaCode])
    }

    static func joinFailed(reason: GroupJoinFailure, viaCode: Bool) -> GroupTelemetryEvent {
        GroupTelemetryEvent(
            name: "group_join_failed",
            properties: ["reason": reason.rawValue, "via_code": viaCode]
        )
    }

    static func memberJoined(memberCount: Int, viaCode: Bool) -> GroupTelemetryEvent {
        GroupTelemetryEvent(
            name: "group_member_joined",
            properties: ["member_count": memberCount, "via_code": viaCode]
        )
    }

    static func memberRemoved(memberCount: Int) -> GroupTelemetryEvent {
        GroupTelemetryEvent(name: "group_member_removed", properties: ["member_count": memberCount])
    }

    static func metaUpdated(hasDestination: Bool, hasStartTime: Bool) -> GroupTelemetryEvent {
        GroupTelemetryEvent(
            name: "group_meta_updated",
            properties: ["has_destination": hasDestination, "has_start_time": hasStartTime]
        )
    }

    static func statusSet(severity: StatusSeverity) -> GroupTelemetryEvent {
        GroupTelemetryEvent(name: "group_status_set", properties: ["severity": String(severity.rawValue)])
    }

    static func statusCleared(byUser: Bool) -> GroupTelemetryEvent {
        GroupTelemetryEvent(name: "group_status_cleared", properties: ["by_user": byUser])
    }

    static func statusAlert(_ suffix: String) -> GroupTelemetryEvent {
        GroupTelemetryEvent(name: "group_status_alert_\(suffix)", properties: nil)
    }

    static func directionsOpened(ageBucket: GroupDirectionsAgeBucket) -> GroupTelemetryEvent {
        GroupTelemetryEvent(name: "group_directions_opened", properties: ["age_bucket": ageBucket.rawValue])
    }

    static func presencePaused(durationBucket: String, cause: GroupPresencePolicy.Cause) -> GroupTelemetryEvent {
        GroupTelemetryEvent(
            name: "group_presence_paused",
            properties: [
                "duration_bucket": durationBucket,
                "cause": cause == .local ? "local" : "relay"
            ]
        )
    }

    static var privacySamples: [GroupTelemetryEvent] {
        [
            inviteSent(),
            inviteOpened(viaCode: false),
            joinFailed(reason: .unknown, viaCode: false),
            memberJoined(memberCount: 2, viaCode: true),
            memberRemoved(memberCount: 1),
            metaUpdated(hasDestination: true, hasStartTime: true),
            statusSet(severity: .alert),
            statusCleared(byUser: true),
            statusAlert("shown"),
            directionsOpened(ageBucket: .seconds),
            presencePaused(durationBucket: "under_2m", cause: .local)
        ]
    }
}

class TelemetryManager {
    static let shared = TelemetryManager()
    
    @AppStorage("enableTelemetry") private var localConsent: Bool = false

    // The remote flag is an operations-only emergency kill switch. Absence of the
    // document/field means no override; only an explicit false can disable telemetry.
    private var remoteAllowed: Bool = true
    private var configListener: ListenerRegistration?
    private var isInitialized = false
    
    private init() {}

    private var effectiveState: TelemetryConsentState {
        TelemetryConsentState(localConsent: localConsent, remoteAllowed: remoteAllowed)
    }
    
    // MARK: - PostHog Setup
    func initializePostHog() {
        let configuration = PostHogConfig(projectToken: "phc_ohRdDdd3VeXqFJPWefGv8vF3ogo4cUHaw9hrMLvDmP8k", host: "https://eu.i.posthog.com")
        // PostHog handles standard properties automatically (OS Version, Screen Dimensions, etc)
        // Opt out automatically if telemetry is disabled
        configuration.optOut = !effectiveState.isEnabled
        PostHogSDK.shared.setup(configuration)
        isInitialized = true

        startRemoteConfigListener()
    }

    /// Listens for the shvm-controlled Firestore emergency kill switch.
    /// Missing documents/fields fail open to the local consent state; an explicit
    /// false can only force everyone off and can never opt anyone in.
    private func startRemoteConfigListener() {
        configListener = Firestore.firestore()
            .collection("config")
            .document("telemetry_settings")
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                if let error {
                    print("TelemetryManager: telemetry settings listener failed: \(error)")
                    return
                }

                let remoteAllowed: Bool
                if let snapshot, snapshot.exists {
                    remoteAllowed = snapshot.get("isTelemetryEnabled") as? Bool ?? true
                } else {
                    remoteAllowed = true
                }
                self.remoteAllowed = remoteAllowed
                self.applyOptState()
            }
    }

    // Call this if the user toggles the local feature flag in Settings.
    func updateLocalConsent(_ enabled: Bool) {
        localConsent = enabled
        applyOptState()
    }

    private func applyOptState() {
        guard isInitialized else { return }
        if effectiveState.isEnabled {
            PostHogSDK.shared.optIn()
        } else {
            PostHogSDK.shared.optOut()
        }
    }
    
    private func shouldTrack() -> Bool {
        effectiveState.isEnabled
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
    // Scope 1.7.3 §0.8: telemetry must not carry a ride identifier or values
    // that fingerprint one. Keep lifecycle events deliberately aggregate-free.
    func trackRideStarted() {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("ride_started")
    }

    func trackRideCompleted() {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("ride_completed")
    }

    func trackRideStartAborted(method: RideStartAbortMethod) {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("ride_start_aborted", properties: [
            "method": method.rawValue
        ])
    }

    // MARK: - v1.8.5 Home dashboard
    func trackHomeDashboardViewed(historyBucket: String) {
        capture(HomeTelemetryContract.dashboardViewed(historyBucket: historyBucket))
    }

    func trackActivityStartCTATapped(persona: RidePersona, method: String) {
        capture(HomeTelemetryContract.startTapped(persona: persona, method: method))
    }

    func trackHomeInsightShown(_ insight: HomeInsight) {
        guard let event = HomeTelemetryContract.insightShown(insight) else { return }
        capture(event)
    }

    func trackHomeRecentActivityOpened(persona: RidePersona) {
        capture(HomeTelemetryContract.recentOpened(persona: persona))
    }

    func trackHomeGroupMapOpened() {
        capture(HomeTelemetryContract.groupMapOpened)
    }

    /// Scope 1.7.3 §2 telemetry contract: failures carry only a coarse cause
    /// and operation shape, never a ride id, point count, timestamp, or route.
    func trackRideDeleteFailed(cause: RideDeletionFailureCause, operation: String) {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("ride_delete_failed", properties: [
            "cause": cause.rawValue,
            "operation": operation
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
    
    // MARK: - 5. User Authentication
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
    
    // MARK: - 6. App Performance & Errors
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
    
    // MARK: - 7. Account & Data Management
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

    func trackHelpOpened() {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("help_opened")
    }

    func trackSupportContactStarted(faqExpandedCount: Int) {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("support_contact_started", properties: [
            "faq_expanded_count": faqExpandedCount
        ])
    }

    // MARK: - 8. v1.6.0 retention taxonomy (A1)
    // Identical event names + property keys/types to Android's AnalyticsManager. NO PII
    // (no lat/lng, no names/emails/titles). Emitted by the feature layer only when a surface
    // is actually shown/acted on.

    /// B1 — reveal_type in {"pr","first_ride","milestone","default"}.
    func trackPostRideRevealShown(revealType: String) {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("post_ride_reveal_shown", properties: [
            "reveal_type": revealType
        ])
    }

    /// B2 — weekly gain-framed recap surfaced.
    func trackWeeklyRecapShown(weekKey: String, rideCount: Int, distanceKm: Double) {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("weekly_recap_shown", properties: [
            "week_key": weekKey,
            "ride_count": rideCount,
            "distance_km": distanceKm
        ])
    }

    /// B3 — active-week streak advanced. `froze` reserved for the freeze/tolerance path.
    func trackWeeklyStreakUpdated(streakWeeks: Int, froze: Bool) {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("weekly_streak_updated", properties: [
            "streak_weeks": streakWeeks,
            "froze": froze
        ])
    }

    /// B4 — in-app review prompt requested (system may or may not show it).
    func trackReviewPromptRequested(platform: String = "ios") {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("review_prompt_requested", properties: [
            "platform": platform
        ])
    }

    /// Age-signal compliance outcome. Category and decision are coarse, non-PII values.
    func trackAgeSignalChecked(platform: String = "ios", category: String, decision: String) {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("age_signal_checked", properties: [
            "platform": platform,
            "category": category,
            "decision": decision
        ])
    }

    // MARK: - 10. Background Tracking Reliability (v1.6.0)
    func trackLocationUpdatesPaused() {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("location_updates_paused")
    }

    func trackLocationUpdatesResumed() {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("location_updates_resumed")
    }

    // MARK: - 11. Group Ride (v1.7.x)
    func trackGroupCreated(durationMinutes: Int, maxMembers: Int, hasDestination: Bool, hasStartTime: Bool) {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("group_created", properties: [
            "duration_minutes": durationMinutes,
            "max_members": maxMembers,
            "has_destination": hasDestination,
            "has_start_time": hasStartTime
        ])
    }

    func trackGroupMemberJoined(memberCount: Int, viaCode: Bool) {
        capture(GroupTelemetryContract.memberJoined(memberCount: memberCount, viaCode: viaCode))
    }

    func trackGroupInviteSent() {
        capture(GroupTelemetryContract.inviteSent())
    }

    func trackGroupInviteOpened(viaCode: Bool) {
        capture(GroupTelemetryContract.inviteOpened(viaCode: viaCode))
    }

    func trackGroupJoinFailed(reason: GroupJoinFailure, viaCode: Bool) {
        capture(GroupTelemetryContract.joinFailed(reason: reason, viaCode: viaCode))
    }

    func trackGroupMemberRemoved(memberCount: Int) {
        capture(GroupTelemetryContract.memberRemoved(memberCount: memberCount))
    }

    func trackGroupMetaUpdated(hasDestination: Bool, hasStartTime: Bool) {
        capture(GroupTelemetryContract.metaUpdated(
            hasDestination: hasDestination,
            hasStartTime: hasStartTime
        ))
    }

    func trackGroupStarted(memberCount: Int) {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("group_started", properties: [
            "member_count": memberCount
        ])
    }

    func trackGroupEnded() {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("group_ended")
    }

    func trackGroupLeft() {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("group_left")
    }

    func trackGroupDegraded() {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("group_degraded")
    }

    func trackGroupStatusSet(severity: StatusSeverity) {
        capture(GroupTelemetryContract.statusSet(severity: severity))
    }

    func trackGroupStatusCleared(byUser: Bool) {
        capture(GroupTelemetryContract.statusCleared(byUser: byUser))
    }

    func trackGroupStatusAlertShown() {
        capture(GroupTelemetryContract.statusAlert("shown"))
    }

    func trackGroupStatusAlertDismissed() {
        capture(GroupTelemetryContract.statusAlert("dismissed"))
    }

    func trackGroupStatusAlertMuted() {
        capture(GroupTelemetryContract.statusAlert("muted"))
    }

    func trackGroupDirectionsOpened(ageBucket: GroupDirectionsAgeBucket) {
        capture(GroupTelemetryContract.directionsOpened(ageBucket: ageBucket))
    }

    func trackGroupPresencePaused(durationBucket: String, cause: GroupPresencePolicy.Cause) {
        capture(GroupTelemetryContract.presencePaused(durationBucket: durationBucket, cause: cause))
    }

    /// SCOPE_1.8.4 §5.3 — the pure contract admits only method/outcome properties.
    func trackVoiceEvent(_ event: VoiceTelemetryEvent) {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture(event.name, properties: event.properties)
    }

    func trackOnboardingCompleted(_ outcome: OnboardingOutcome) {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("onboarding_completed", properties: outcome.telemetryProperties)
    }

    private func capture(_ event: GroupTelemetryEvent) {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture(event.name, properties: event.properties)
    }

    private func capture(_ event: HomeTelemetryEvent) {
        guard shouldTrack() else { return }
        let properties: [String: Any]? = event.properties.isEmpty
            ? nil
            : event.properties.mapValues { $0 as Any }
        PostHogSDK.shared.capture(event.name, properties: properties)
    }
}
