import Foundation
enum AutoPausePreference {
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: "intelligentAutoPause") == nil || defaults.bool(forKey: "intelligentAutoPause")
    }
}
