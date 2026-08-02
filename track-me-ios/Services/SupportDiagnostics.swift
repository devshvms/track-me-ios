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

struct SupportDiagnosticsLabels {
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
    let signedIn: String

    static let english = SupportDiagnosticsLabels(
        appVersion: "App version",
        iosVersion: "iOS version",
        device: "Device",
        appLanguage: "App language",
        deviceLocale: "Device locale",
        units: "Units",
        locationAuthorization: "Location authorization",
        notificationAuthorization: "Notification authorization",
        lowPowerMode: "Low Power Mode",
        backgroundRefresh: "Background refresh",
        signedIn: "Signed in"
    )
}

enum SupportDiagnostics {
    /// Pure and intentionally unable to access Core Location, SwiftData, or ride identifiers.
    static func render(_ input: SupportDiagnosticsInput, labels: SupportDiagnosticsLabels = .english) -> String {
        """
        \(labels.appVersion): \(input.appVersion)
        \(labels.iosVersion): \(input.iosVersion)
        \(labels.device): \(input.device)
        \(labels.appLanguage): \(input.appLanguage)
        \(labels.deviceLocale): \(input.deviceLocale)
        \(labels.units): \(input.units)
        \(labels.locationAuthorization): \(input.locationAuthorization)
        \(labels.notificationAuthorization): \(input.notificationAuthorization)
        \(labels.lowPowerMode): \(input.lowPowerMode)
        \(labels.backgroundRefresh): \(input.backgroundRefresh)
        \(labels.signedIn): \(input.signedIn)
        """
    }
}
