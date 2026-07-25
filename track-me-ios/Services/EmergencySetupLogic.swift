import Foundation

struct EmergencySetupLogic {
    static func isSetupComplete(isSetupComplete: Bool, contactCount: Int) -> Bool {
        return isSetupComplete && contactCount >= 1
    }
}
