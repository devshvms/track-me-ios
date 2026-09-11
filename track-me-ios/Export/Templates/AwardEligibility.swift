import Foundation

/// What a ride earned at the moment it was saved, as persisted on its row (SCOPE_1.8.9 §13).
nonisolated struct EarnedReveal: Equatable {
    let kind: RevealKind
    /// Metres for a distance PR, active milliseconds for a duration PR.
    let previousBest: Double?
    let milestoneCount: Int?
}

/// Everything The Award draws, already checked against the ride's stored figures.
nonisolated struct AwardFacts: Equatable {
    let kind: RevealKind
    let previousBest: Double?
    let milestoneCount: Int?
    /// How much of the ring the old record covers; the rest is new ground. 1 with no record.
    let previousFraction: Float
}

/// The one gate for The Award (SCOPE_1.8.9 §6.4) — the twin of Android's `AwardEligibility`.
/// `RevealSelector` chose the outcome at save; this decides whether it is still **true** of the ride
/// as stored, because a PR chosen on live distance can be shortened by processing afterwards, and gold
/// on a false claim is exactly the decoration the template's discipline forbids.
nonisolated enum AwardEligibility {

    static func facts(
        _ reveal: EarnedReveal?,
        source: String,
        storedDistanceMeters: Double,
        storedActiveMillis: Int64?
    ) -> AwardFacts? {
        guard let reveal, RideSource.earnsProgress(source) else { return nil }
        switch reveal.kind {
        case .standard:
            return nil
        case .firstRide:
            return AwardFacts(kind: .firstRide, previousBest: nil, milestoneCount: nil, previousFraction: 1)
        case .milestone:
            guard let count = reveal.milestoneCount else { return nil }
            return AwardFacts(kind: .milestone, previousBest: nil, milestoneCount: count, previousFraction: 1)
        case .distancePR:
            guard let previous = reveal.previousBest, previous > 0, storedDistanceMeters > previous else { return nil }
            return AwardFacts(kind: .distancePR, previousBest: previous, milestoneCount: nil,
                              previousFraction: Float(previous / storedDistanceMeters))
        case .durationPR:
            guard let previous = reveal.previousBest, previous > 0,
                  let active = storedActiveMillis, Double(active) > previous else { return nil }
            return AwardFacts(kind: .durationPR, previousBest: previous, milestoneCount: nil,
                              previousFraction: Float(previous / Double(active)))
        }
    }

    /// Reads the persisted columns; an unknown kind from a newer build is treated as none.
    static func parse(kind: String?, previousBest: Double?, milestoneCount: Int?) -> EarnedReveal? {
        guard let kind, let parsed = RevealKind(wireName: kind) else { return nil }
        return EarnedReveal(kind: parsed, previousBest: previousBest, milestoneCount: milestoneCount)
    }
}
