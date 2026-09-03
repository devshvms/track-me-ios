import Foundation

nonisolated enum TrackingV2ReplayEvent: Sendable {
    case sample(TrackingV2Sample)
    case discontinuity
}

nonisolated struct TrackingV2ReplayScenario: Sendable {
    let id: String
    let persona: RidePersona
    let events: [TrackingV2ReplayEvent]
}

/// Pure adapter shared by synthetic fixtures now and a future user-initiated local export later.
nonisolated enum TrackingV2ReplayHarness {
    static func run(
        _ scenario: TrackingV2ReplayScenario,
        estimator: TrackingV2Estimator = TrackingV2Estimator()
    ) -> TrackingV2Snapshot {
        estimator.reset(persona: scenario.persona)
        for event in scenario.events {
            switch event {
            case .sample(let sample): estimator.add(sample)
            case .discontinuity: estimator.markDiscontinuity()
            }
        }
        return estimator.finish()
    }
}
