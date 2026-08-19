import Foundation

enum LocationAuth { case notDetermined, whenInUse, always, denied, restricted }

enum StartAction: Equatable {
    case requestWhenInUse    // notDetermined: present the native prompt from the user's Start action
    case begin               // whenInUse or always: start the ride NOW
    case deniedRecovery      // denied/restricted: route to settings-recovery (prompt 25) / toast
}

enum LocationStartDecision {
    /// What to do when the user taps Start.
    static func action(for status: LocationAuth) -> StartAction {
        switch status {
        case .notDetermined:      return .requestWhenInUse
        case .whenInUse, .always: return .begin
        case .denied, .restricted: return .deniedRecovery
        }
    }

    /// Whether we should opportunistically ask for the Always upgrade.
    /// Only when we're on WhenInUse and have never asked before — this is what
    /// prevents the silent-no-op trap AND avoids nagging.
    static func shouldRequestAlwaysUpgrade(status: LocationAuth, hasAskedAlways: Bool) -> Bool {
        status == .whenInUse && !hasAskedAlways
    }
}
