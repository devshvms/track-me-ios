import SwiftData
import Foundation

/// Legacy SwiftData record retained only long enough to purge pre-retirement stores safely.
@Model final class EmergencySettings {
    var isSetupComplete: Bool
    var messageTemplate: String

    // premiumToken and broadcastIntervalSeconds (parity fields) are unused on iOS v1, so omitted for now.

    init(isSetupComplete: Bool = false,
         messageTemplate: String = "EMERGENCY! I need help. My last known location is: [Location Link]. Battery: [Battery Percent]. Device: [Device Name]. Time: [Timestamp]") {
        self.isSetupComplete = isSetupComplete
        self.messageTemplate = messageTemplate
    }
}
