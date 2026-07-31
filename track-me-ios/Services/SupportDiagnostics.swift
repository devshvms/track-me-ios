import Foundation

struct SupportDiagnosticsInput {
    let appVersion: String
    let iosVersion: String
    let device: String
    let appLanguage: String
    let deviceLocale: String
    let units: String
    let locationAuthorization: String
    let notificationAuthorization: String
    let lowPowerMode: String
    let backgroundRefresh: String
    let signedIn: Bool
}

enum SupportDiagnostics {
    /// Pure and intentionally unable to access Core Location, SwiftData, or ride identifiers.
    static func render(_ input: SupportDiagnosticsInput) -> String {
        """
        App version: \(input.appVersion)
        iOS version: \(input.iosVersion)
        Device: \(input.device)
        App language: \(input.appLanguage)
        Device locale: \(input.deviceLocale)
        Units: \(input.units)
        Location authorization: \(input.locationAuthorization)
        Notification authorization: \(input.notificationAuthorization)
        Low Power Mode: \(input.lowPowerMode)
        Background refresh: \(input.backgroundRefresh)
        Signed in: \(input.signedIn)
        """
    }
}
