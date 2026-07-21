import Foundation

/// B4 iOS in-app review gating. Applies the pure `ReviewPromptPolicy`, records the attempt, and
/// emits telemetry; the actual system prompt is fired by the caller via `@Environment(\.requestReview)`
/// (it must run from a live scene). Parity with Android's `ReviewPrompter`.
///
/// Apple silently throttles and its API never confirms a prompt was shown, so we record an
/// *attempt* and describe a request — not a display or a conversion.
@MainActor
enum ReviewPrompter {
    private static let keyLastAt = "review_last_prompted_at"
    private static let keyLastVersion = "review_last_prompted_version"

    private static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Returns true if the caller should now fire `requestReview()`. When true, the attempt has
    /// already been recorded and telemetry sent, so it is one attempt per (version, 90-day) window.
    /// Must only be called at a positive moment — never after error / SOS / storage-low / discard.
    static func shouldRequestAndRecord(goodRideCount: Int, defaults: UserDefaults = .standard) -> Bool {
        let nowMillis = Int64(Date().timeIntervalSince1970 * 1000)
        let eligible = ReviewPromptPolicy.isEligible(
            goodRideCount: goodRideCount,
            lastPromptedAtMillis: defaults.object(forKey: keyLastAt) as? Int64 ?? 0,
            lastPromptedVersion: defaults.string(forKey: keyLastVersion),
            currentVersion: currentVersion,
            nowMillis: nowMillis
        )
        guard eligible else { return false }
        // Record BEFORE the prompt fires so a failure/retry can't double-ask.
        defaults.set(nowMillis, forKey: keyLastAt)
        defaults.set(currentVersion, forKey: keyLastVersion)
        TelemetryManager.shared.trackReviewPromptRequested()
        return true
    }
}
