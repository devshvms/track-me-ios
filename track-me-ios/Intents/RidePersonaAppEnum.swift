import AppIntents

/// The App Intents representation is deliberately the shipped model enum itself. Its raw values
/// are the cross-platform wire contract and must never be renamed for Siri copy.
extension RidePersona: AppEnum {
    nonisolated static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Mode")
    }

    nonisolated static var caseDisplayRepresentations: [RidePersona: DisplayRepresentation] {
        [
            .auto: DisplayRepresentation(title: "Auto", image: .init(systemName: "sparkles")),
            .walk: DisplayRepresentation(
                title: "Walk",
                image: .init(systemName: "figure.walk"),
                synonyms: ["Walking", "Hike", "Hiking"]
            ),
            .run: DisplayRepresentation(
                title: "Run",
                image: .init(systemName: "figure.run"),
                synonyms: ["Running", "Jog", "Jogging"]
            ),
            .cycling: DisplayRepresentation(
                title: "Cycling",
                image: .init(systemName: "bicycle"),
                synonyms: ["Ride", "Bike", "Biking", "Cycle"]
            ),
            .bikeDrive: DisplayRepresentation(
                title: "Motorbike",
                image: .init(systemName: "motorcycle.fill"),
                synonyms: ["Motorcycle", "Motorcycling"]
            ),
            .carDrive: DisplayRepresentation(
                title: "Car",
                image: .init(systemName: "car.fill"),
                synonyms: ["Drive", "Driving"]
            )
        ]
    }
}
