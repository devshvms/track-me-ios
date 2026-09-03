import Foundation

enum DebugSettings {
    static let modeEnabledKey = "debugModeEnabled"
    static let autoPauseKey = "intelligentAutoPause"
    static let postProcessingKey = "enableGPSPostProcessing"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: modeEnabledKey)
    }

    static func enable(_ defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: modeEnabledKey)
    }

    /// Restores only preferences owned by Debug Settings; customer preferences are untouched.
    static func disableAndReset(_ defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: autoPauseKey)
        defaults.set(true, forKey: postProcessingKey)
        // Lock last so a partial write can never leave unlocked disabled algorithms behind.
        defaults.set(false, forKey: modeEnabledKey)
    }
}

/// Pure, monotonic-time gate used by the Help & Feedback unlock action and its tests.
struct ConsecutiveTapUnlock {
    let requiredTaps: Int
    let maximumGap: TimeInterval
    private(set) var tapCount = 0
    private var lastTapUptime: TimeInterval?

    init(requiredTaps: Int = 5, maximumGap: TimeInterval = 2) {
        precondition(requiredTaps > 0)
        precondition(maximumGap >= 0)
        self.requiredTaps = requiredTaps
        self.maximumGap = maximumGap
    }

    mutating func registerTap(uptime: TimeInterval) -> Bool {
        if let lastTapUptime,
           uptime >= lastTapUptime,
           uptime - lastTapUptime <= maximumGap {
            tapCount += 1
        } else {
            tapCount = 1
        }
        lastTapUptime = uptime

        guard tapCount >= requiredTaps else { return false }
        reset()
        return true
    }

    mutating func reset() {
        tapCount = 0
        lastTapUptime = nil
    }
}
