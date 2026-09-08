import Foundation
import SwiftUI
import PostHog
import FirebaseFirestore

/// Pure consent contract shared with Android: local opt-in is required, while the
/// remote flag can only force telemetry off.
/// TASK-250, shvm: whether *this build, on this machine* may deliver telemetry at all.
///
/// A third gate beside consent and the remote kill switch, and the only one that is a property of
/// the build rather than the user. Every debug run and every simulator session was landing in the
/// same PostHog project and Crashlytics app as real riders. Not a privacy problem — nobody's data
/// leaks — but a data-quality one, and quiet: developer sessions inflate counts and shape a funnel
/// out of runs that were never real usage. A metric nobody trusts is worse than one nobody has.
///
/// Kept in step with Android's `TelemetryEnvironment`.
enum TelemetryEnvironment {

    /// Deliberately not "release builds only": a release build running in the Simulator is still
    /// not a rider.
    static let allowsDelivery: Bool = {
        #if DEBUG
        return false
        #elseif targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }()

    /// Human-readable reason, for the one log line that explains a silent analytics build.
    static var suppressionReason: String? {
        #if DEBUG
        return "debug build"
        #elseif targetEnvironment(simulator)
        return "simulator"
        #else
        return nil
        #endif
    }
}

struct TelemetryConsentState {
    let localConsent: Bool
    let remoteAllowed: Bool
    /// TASK-250. **No default on purpose** — a default would let a future call site silently opt
    /// back into delivery from a debug build, which is the shape of the TASK-246 defect: a
    /// parameter that reads as harmless and is wrong on exactly the paths that omit it.
    let environmentAllowsDelivery: Bool

    /// This term can only ever subtract. It never grants delivery the user did not consent to,
    /// which is why it composes with `&&` rather than replacing the other two.
    var isEnabled: Bool { localConsent && remoteAllowed && environmentAllowsDelivery }
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
        TelemetryConsentState(
            localConsent: localConsent,
            remoteAllowed: remoteAllowed,
            environmentAllowsDelivery: TelemetryEnvironment.allowsDelivery
        )
    }
    
    // MARK: - PostHog Setup
    func initializePostHog() {
        // TASK-250: a build that may not deliver does not start the SDK at all.
        //
        // Opting out would already stop capture, and every event below checks the same flag — but
        // "no SDK, no queue, no network" is a guarantee that does not depend on getting every call
        // site right, and it is the guarantee shvm asked for. The remote config listener goes with
        // it: its only job is to feed the kill switch, which cannot change an answer already false.
        guard TelemetryEnvironment.allowsDelivery else {
            // NSLog rather than print, so the reason reaches the system log and is visible on a
            // build nobody is attached to -- the house style elsewhere in this codebase.
            NSLog("TrackMe: telemetry delivery suppressed (%@)", TelemetryEnvironment.suppressionReason ?? "unknown")
            isInitialized = true
            return
        }

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
    
    // MARK: - Export / share funnel (TASK-305)
    //
    // The share artifact is the only channel that compounds, and until 1.8.7 it was completely
    // dark on both platforms: sixty days of PostHog matching %export%, %replay%, %image%,
    // %artifact%, %share% returned only the live-location link events and the account ZIP. Nobody
    // could say whether a single route image had ever been exported.
    //
    // Guardrail: count exports, never contents. No coordinates, ride titles, names or emails.
    // Byte-for-byte parity with Android's AnalyticsManager — same event names, same properties.

    /// The preview opened. Top of the funnel; every ratio below is measured against it.
    func trackExportPreviewOpened(surface: String) {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("export_preview_opened", properties: ["surface": surface])
    }

    /// A style control changed — the control's identity, never its value. Recording the value
    /// would make the event a description of the user's export, which the guardrail forbids.
    func trackExportStyleChanged(control: String) {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("export_style_changed", properties: ["control": control])
    }

    /// A render finished or failed. One event with both fields, because a render that fails after
    /// forty seconds and one that fails instantly are different bugs.
    func trackExportRendered(kind: String, success: Bool, durationMillis: Int64, failureReason: String? = nil) {
        guard shouldTrack() else { return }
        var properties: [String: Any] = [
            "kind": kind,
            "success": success,
            "duration_ms": durationMillis
        ]
        if let failureReason { properties["failure_reason"] = failureReason }
        PostHogSDK.shared.capture("export_rendered", properties: properties)
    }

    /// Written to Photos. A real outcome even when nothing is then shared.
    func trackExportSavedToGallery(kind: String, success: Bool) {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("export_saved_to_gallery", properties: ["kind": kind, "success": success])
    }

    /// The share sheet was presented. Distinct from `export_shared` — see that comment.
    func trackExportShareSheetOpened(kind: String) {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("export_share_sheet_opened", properties: ["kind": kind])
    }

    /// The user completed a share.
    ///
    /// Two events rather than one, for the TASK-289 reason: `group_invite_sent` fired on sheet
    /// *presentation*, so its 2-of-42 baseline counted openings and could not separate "nobody
    /// shared" from "everybody opened the sheet and backed out". `export_shared ÷ export_rendered`
    /// is this task's stated success metric, and a baseline cannot be retrofitted.
    ///
    /// `UIActivityViewController` hands us the chosen activity type. It is **deliberately not
    /// recorded**, matching Android: a share target is a record of what else is on someone's phone
    /// and how they use it. Overruling that is shvm's call and should be written down.
    func trackExportShared(kind: String) {
        guard shouldTrack() else { return }
        PostHogSDK.shared.capture("export_shared", properties: ["kind": kind])
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
