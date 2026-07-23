import SwiftData
import Foundation

@Model final class EmergencyContact {
    var name: String
    var phoneNumber: String
    var medium: String        // "SMS" (parity field; only SMS dispatched on iOS v1)
    var createdAt: Date

    init(name: String, phoneNumber: String, medium: String = "SMS", createdAt: Date = .now) {
        self.name = name
        self.phoneNumber = phoneNumber
        self.medium = medium
        self.createdAt = createdAt
    }
}
