import Foundation

enum RidePersona: String, CaseIterable {
    case auto = "AUTO", walk = "WALK", run = "RUN", cycling = "CYCLING", bikeDrive = "BIKE_DRIVE", carDrive = "CAR_DRIVE"

    var displayName: String {
        switch self { case .auto: "Auto"; case .walk: "Walk"; case .run: "Run"; case .cycling: "Cycling"; case .bikeDrive: "BikeDrive"; case .carDrive: "CarDrive" }
    }
    var emoji: String {
        switch self { case .auto: "✨"; case .walk: "🚶"; case .run: "🏃"; case .cycling: "🚴"; case .bikeDrive: "🏍️"; case .carDrive: "🚗" }
    }
    static func fromStoredName(_ raw: String?) -> RidePersona { raw.flatMap(RidePersona.init(rawValue:)) ?? .auto }
}
