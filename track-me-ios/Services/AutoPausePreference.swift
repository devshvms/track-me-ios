import Foundation

enum AutoPausePreference {
    /// Locked mode always uses supported behavior. A stored override is active only while the
    /// locally unlocked Debug Settings mode is enabled.
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        isEnabled(defaults, debugModeEnabled: DebugSettings.isEnabled(defaults))
    }

    static func isEnabled(
        _ defaults: UserDefaults,
        debugModeEnabled: Bool
    ) -> Bool {
        guard debugModeEnabled else { return true }
        return defaults.object(forKey: DebugSettings.autoPauseKey) == nil
            || defaults.bool(forKey: DebugSettings.autoPauseKey)
    }
}
