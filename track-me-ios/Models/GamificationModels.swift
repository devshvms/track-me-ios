import Foundation

struct GamificationLevel: Equatable {
    let level: Int
    let name: String
    let requiredActiveMinutes: Int64
}

enum GamificationDefinitions {
    static let currentVersion = 1

    static let levels: [GamificationLevel] = [
        GamificationLevel(level: 1, name: "Starter", requiredActiveMinutes: 0),
        GamificationLevel(level: 2, name: "Moving", requiredActiveMinutes: 120),
        GamificationLevel(level: 3, name: "Regular", requiredActiveMinutes: 600),
        GamificationLevel(level: 4, name: "Explorer", requiredActiveMinutes: 1800),
        GamificationLevel(level: 5, name: "Enduring", requiredActiveMinutes: 4500),
        GamificationLevel(level: 6, name: "Pathfinder", requiredActiveMinutes: 9000)
    ]

    static func getLevel(forMinutes activeMinutes: Int64) -> GamificationLevel {
        // Assume sorted from highest to lowest or we search from end.
        // It's already sorted by level ascending.
        return levels.last { activeMinutes >= $0.requiredActiveMinutes } ?? levels[0]
    }
}
