import Foundation

/// Pure B4 eligibility for the in-app review prompt (iOS). Identical rules to Android's
/// `ReviewPromptPolicy`: at least `minGoodRides` good rides, not already asked on this app
/// version, and at least `cooldownDays` since the last request — on top of Apple's own throttle
/// (≈3/yr). Nonisolated so it's usable from any context and unit-testable.
nonisolated enum ReviewPromptPolicy {
    static let minGoodRides = 3
    static let cooldownDays: Double = 90
    private static let dayMillis: Int64 = 24 * 60 * 60 * 1000

    static func isEligible(
        goodRideCount: Int,
        lastPromptedAtMillis: Int64,
        lastPromptedVersion: String?,
        currentVersion: String,
        nowMillis: Int64
    ) -> Bool {
        if goodRideCount < minGoodRides { return false }
        if lastPromptedVersion == currentVersion { return false }
        if lastPromptedAtMillis != 0 && nowMillis - lastPromptedAtMillis < Int64(cooldownDays) * dayMillis {
            return false
        }
        return true
    }
}
