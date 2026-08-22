import Foundation

enum RidePersona: String, CaseIterable, Hashable, Sendable {
    case auto = "AUTO", walk = "WALK", run = "RUN", cycling = "CYCLING", bikeDrive = "BIKE_DRIVE", carDrive = "CAR_DRIVE"

    var displayName: String {
        switch self { case .auto: "Auto"; case .walk: "Walk"; case .run: "Run"; case .cycling: "Cycling"; case .bikeDrive: "Motorbike"; case .carDrive: "Car" }
    }
    var systemImage: String {
        switch self {
        case .auto: "sparkles"
        case .walk: "figure.walk"
        case .run: "figure.run"
        case .cycling: "bicycle"
        case .bikeDrive: "motorcycle.fill"
        case .carDrive: "car.fill"
        }
    }
    var emoji: String {
        switch self { case .auto: "✨"; case .walk: "🚶"; case .run: "🏃"; case .cycling: "🚴"; case .bikeDrive: "🏍️"; case .carDrive: "🚗" }
    }
    static func fromStoredName(_ raw: String?) -> RidePersona { raw.flatMap(RidePersona.init(rawValue:)) ?? .auto }
}
