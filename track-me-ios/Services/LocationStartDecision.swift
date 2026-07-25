import Foundation

enum LocationAuth { case notDetermined, whenInUse, always, denied, restricted }

enum StartAction: Equatable {
    case showPrimer          // notDetermined: show the explanation sheet, then request WhenInUse
    case requestWhenInUse    // notDetermined path after the primer's "Continue"
    case begin               // whenInUse or always: start the ride NOW
    case deniedRecovery      // denied/restricted: route to settings-recovery (prompt 25) / toast
}

enum LocationStartDecision {
    /// What to do when the user taps Start (or returns from the primer).
    static func action(for status: LocationAuth, afterPrimer: Bool) -> StartAction {
        switch status {
        case .notDetermined:      return afterPrimer ? .requestWhenInUse : .showPrimer
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
