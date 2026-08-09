import SwiftData
import Foundation

/// Legacy SwiftData record retained only long enough to purge pre-retirement stores safely.
@Model final class EmergencyContact {
    var name: String
    var phoneNumber: String
    var medium: String
    var createdAt: Date

    init(name: String, phoneNumber: String, medium: String = "SMS", createdAt: Date = .now) {
        self.name = name
        self.phoneNumber = phoneNumber
        self.medium = medium
        self.createdAt = createdAt
    }
}
