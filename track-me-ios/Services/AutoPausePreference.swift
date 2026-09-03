import Foundation

enum AutoPausePreference {
    /// Release builds always use the supported production behavior. The stored key remains for
    /// controlled debug scenarios, but an old customer override cannot silently disable auto-pause
    /// after its Settings control has been removed.
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        isEnabled(defaults, debugOverridesAvailable: debugOverridesAvailable)
    }

    static func isEnabled(
        _ defaults: UserDefaults,
        debugOverridesAvailable: Bool
    ) -> Bool {
        guard debugOverridesAvailable else { return true }
        return defaults.object(forKey: "intelligentAutoPause") == nil
            || defaults.bool(forKey: "intelligentAutoPause")
    }

    private static var debugOverridesAvailable: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
