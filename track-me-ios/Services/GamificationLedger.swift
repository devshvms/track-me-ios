import Foundation

/// TASK-276: when each level was reached, and what the rider was doing to reach it.
///
/// **Derived, never stored.** An "achieved on" date looks like something to persist at unlock time,
/// and persisting it would be wrong: `GAMIFICATION.md` §7 requires that deleting a ride recomputes
/// progress, and a stored date would survive the deletion of the very ride that earned it.
/// Replaying the qualifying rides in order costs one pass and cannot disagree with the ride store,
/// because it *is* the ride store.
///
/// The consequence is deliberate and worth stating: delete rides until you fall below a threshold
/// and re-cross it later, and the displayed date moves. That is the truthful answer, and it is the
/// same behaviour §7 already requires of badges.
///
/// Epoch milliseconds rather than `Date` throughout, matching Android exactly, so a shared vector
/// file can validate both platforms against one set of expectations.
enum GamificationLedger {

    /// One qualifying, recorded ride reduced to what this derivation needs.
    struct RideFact: Codable, Equatable, Sendable {
        let atEpochMillis: Int64
        let personaRaw: String
        let activeDurationMillis: Int64
        let distanceMeters: Double
    }

    /// What one persona contributed up to the moment a level was reached.
    struct PersonaContribution: Codable, Equatable, Sendable {
        let personaRaw: String
        let activeDurationMillis: Int64
        let distanceMeters: Double
    }

    struct LevelAchievement: Codable, Equatable, Sendable {
        let levelId: String
        /// Nil while the level is still ahead, and for level 1 before the first ride.
        let achievedAtEpochMillis: Int64?
        /// Everything that counted toward it, largest contribution first. Empty until achieved.
        let personaSplit: [PersonaContribution]
    }

    /// One entry per level, in level order.
    ///
    /// Level 1 is the joining date rather than a threshold crossing: its threshold is zero, so every
    /// rider satisfies it before they have done anything, and "reached at 0 minutes" says nothing.
    /// The first recorded ride is the honest answer to when the journey started.
    static func derive(_ rides: [RideFact]) -> [LevelAchievement] {
        let ordered = rides.sorted { $0.atEpochMillis < $1.atEpochMillis }
        var result: [LevelAchievement] = []

        // Minutes accumulate in milliseconds and divide once, matching GamificationEngine.
        // Dividing per ride and summing would round each ride down and drift below the engine.
        var millis: Int64 = 0
        var byPersona: [String: PersonaContribution] = [:]
        var order: [String] = []
        var index = 0

        func accumulate(_ ride: RideFact) {
            let existing = byPersona[ride.personaRaw]
            if existing == nil { order.append(ride.personaRaw) }
            byPersona[ride.personaRaw] = PersonaContribution(
                personaRaw: ride.personaRaw,
                activeDurationMillis: (existing?.activeDurationMillis ?? 0) + ride.activeDurationMillis,
                distanceMeters: (existing?.distanceMeters ?? 0) + ride.distanceMeters
            )
        }

        /// Copies the running totals so a later level cannot mutate an earlier level's answer.
        /// Ties break on persona name so two personas with identical time do not reorder.
        func snapshot() -> [PersonaContribution] {
            order.compactMap { byPersona[$0] }.sorted {
                if $0.activeDurationMillis != $1.activeDurationMillis {
                    return $0.activeDurationMillis > $1.activeDurationMillis
                }
                return $0.personaRaw < $1.personaRaw
            }
        }

        for (levelIndex, level) in GamificationEngine.levels.enumerated() {
            if levelIndex == 0 {
                if let first = ordered.first {
                    millis += first.activeDurationMillis
                    accumulate(first)
                    index = 1
                    result.append(LevelAchievement(
                        levelId: level.id,
                        achievedAtEpochMillis: first.atEpochMillis,
                        personaSplit: snapshot()
                    ))
                } else {
                    result.append(LevelAchievement(
                        levelId: level.id, achievedAtEpochMillis: nil, personaSplit: []
                    ))
                }
                continue
            }

            while millis / 60_000 < level.thresholdMinutes && index < ordered.count {
                let ride = ordered[index]
                millis += ride.activeDurationMillis
                accumulate(ride)
                index += 1
            }

            let reached = millis / 60_000 >= level.thresholdMinutes && !ordered.isEmpty
            result.append(LevelAchievement(
                levelId: level.id,
                achievedAtEpochMillis: reached ? ordered[index - 1].atEpochMillis : nil,
                personaSplit: reached ? snapshot() : []
            ))
        }
        return result
    }
}
