import CoreLocation

enum LocationRecovery {
    /// True when the status is a user/OS denial that a Settings visit can resolve.
    static func shouldOfferSettingsRecovery(for status: CLAuthorizationStatus) -> Bool {
        switch status {
        case .denied, .restricted: return true
        default: return false
        }
    }
}
